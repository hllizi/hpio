-- | The actual Linux 'sysfs' GPIO implementation. This implementation
-- will only function properly on Linux systems with a 'sysfs' GPIO
-- subsystem, obviously.
--
-- See the <https://www.kernel.org/doc/Documentation/gpio/sysfs.txt
-- Linux kernel documentation> for the definitive description of the
-- Linux 'sysfs'-based GPIO API and the terminology used in this
-- module.
--
-- == Pin numbering
--
-- The 'sysfs' GPIO implementation in this module uses the same pin
-- numbering scheme as the 'sysfs' GPIO filesystem. For example, 'Pin'
-- 13 corresponds to @gpio13@ in the 'sysfs' filesystem. Note that the
-- 'sysfs' pin numbering scheme is almost always different than the
-- pin numbering scheme given by the platform/hardware documentation.
-- Consult your platform documentation for the mapping of pin numbers
-- between the two namespaces.

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module System.GPIO.Linux.Sysfs.IO
         ( -- * SysfsIOT transformer
           SysfsIOT(..)
         , SysfsIO
         , runSysfsIO
         ) where

import Prelude hiding (readFile, writeFile)
import Control.Applicative
import Control.Monad (filterM)
import Control.Monad.Catch
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Char (toLower)
import Data.List (isPrefixOf, sort)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt(..))
import qualified Language.C.Inline as C (include)
import qualified Language.C.Inline.Interruptible as CI
import System.Directory (doesDirectoryExist, doesFileExist, getDirectoryContents)
import System.FilePath ((</>), takeFileName)
import System.GPIO.Linux.Sysfs.Monad
import System.GPIO.Linux.Sysfs.Free
import System.GPIO.Linux.Sysfs.Types
import System.GPIO.Linux.Sysfs.Util
import System.GPIO.Types
import qualified System.IO as IO (writeFile)
import qualified System.IO.Strict as IOS (readFile)
import System.Posix.IO (OpenMode(ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd)
import Text.Read (readMaybe)

-- Our poll(2) wrapper.
--
-- Note: standard practice for Haskell timeouts/delays is to use
-- microseconds; however, poll(2) takes a __milli__second timeout.
-- 'pollSysfs' takes a microsecond timeout argument, but the
-- implementation converts it to milliseconds (in C code) before
-- passing it to poll(2).

-- Because it may block, we use the 'interruptible' variant of the C
-- FFI. This means we need to check for EINTR and try again when it
-- occurs.
--
-- We assume that 'Language.C.Inline.Interruptible' preserves errno
-- when returning from the FFI call!

C.include "<errno.h>"
C.include "<poll.h>"
C.include "<stdint.h>"
C.include "<unistd.h>"

-- Using poll(2) to wait for GPIO interrupts is a bit flaky:
--
-- On certain combinations of kernels+hardware, a "dummy read(2)" is
-- needed before the poll(2) operation. As read(2) on a GPIO sysfs
-- pin's "value" file doesn't block, it doesn't hurt to do this in all
-- cases, anyway.
--
-- The Linux man page for poll(2) states that setting POLLERR in the
-- 'events' field is meaningless. However, the kernel GPIO
-- documentation states: "If you use poll(2), set the events POLLPRI
-- and POLLERR." Here we do what the kernel documentation says.
--
-- When poll(2) returns, an lseek(2) is needed before read(2), per the
-- Linux kernel documentation.
--
-- It appears that poll(2) on the GPIO sysfs pin's "value" file always
-- returns POLLERR in 'revents', even if there is no error. (This is
-- supposedly true for all sysfs files, not just for GPIO.) We simply
-- ignore that bit and only consider the return value of poll(2) to
-- determine whether an error has occurred. (Presumably, if POLLERR is
-- set and poll(2) returns no error, then the subsequent lseek(2) or
-- read(2) will fail.)
--
-- Ref:
-- https://e2e.ti.com/support/dsp/davinci_digital_media_processors/f/716/t/182883
-- http://www.spinics.net/lists/linux-gpio/msg03848.html
-- https://www.kernel.org/doc/Documentation/gpio/sysfs.txt
-- http://stackoverflow.com/questions/16442935/why-doesnt-this-call-to-poll-block-correctly-on-a-sysfs-device-attribute-file
 -- http://stackoverflow.com/questions/27411013/poll-returns-both-pollpri-pollerr
pollSysfs :: Fd -> Int -> IO CInt
pollSysfs fd timeout =
  let cfd = fromIntegral fd
      ctimeout = fromIntegral timeout
  in
    [CI.block| int {
         uint8_t dummy;
         if (read($(int cfd), &dummy, 1) == -1) {
             return -1;
         }

         struct pollfd fds = { .fd = $(int cfd), .events = POLLPRI|POLLERR, .revents = 0 };

         int timeout_in_ms = ($(int ctimeout) > 0) ? ($(int ctimeout) / 1000) : $(int ctimeout);

         int poll_result = poll(&fds, 1, timeout_in_ms);
         if (poll_result == -1)  {
             return -1;
         }
         if (lseek(fds.fd, 0, SEEK_SET) == -1) {
             return -1;
         }
         return poll_result;
     } |]

-- | A monad transformer which adds Linux 'sysfs' GPIO computations to
-- an inner monad 'm'.
--
-- == Interactions with threads
-- Some parts of this GPIO implementation use the Haskell C FFI, and
-- may block on C I/O operations. (Specifically,
-- 'System.GPIO.Free.readPin' will block in the C FFI until its event
-- is triggered.) When using this implementation with GHC, you should
-- compile your program with the @-threaded@ option, so that threads
-- performing these blocking operations do not block other Haskell
-- threads in the system.
--
-- Note that the C FFI bits in this implementation are marked as
-- 'interruptible', so that, on versions of GHC later than 7.8.1,
-- functions such as 'Control.Concurent.throwTo' will work properly
-- when targeting a Haskell thread which is using this implementation.
--
-- (On Haskell implementations other than GHC, the threading
-- implications are unknown; see the implementation's notes on how its
-- threading system interacts with the C FFI.)
newtype SysfsIOT m a =
  SysfsIOT { runSysfsIOT :: m a }
  deriving (Alternative,Applicative,Functor,Monad,MonadIO,MonadThrow,MonadCatch,MonadMask)

-- | A convenient specialization of 'SysfsT' which runs GPIO eDSL
-- computations in 'IO'.
type SysfsIO a = SysfsT (SysfsIOT IO) (SysfsIOT IO) a

-- | Run a 'SysfsIO' computation in the 'IO' monad and return the
-- result.
runSysfsIO :: SysfsIO a -> IO a
runSysfsIO action = runSysfsIOT $ runSysfsT action

instance (MonadIO m, MonadThrow m) => MonadSysfs (SysfsIOT m) where
  sysfsIsPresent = liftIO sysfsIsPresentIO
  pinIsExported = liftIO . pinIsExportedIO
  pinHasDirection = liftIO . pinHasDirectionIO
  pinHasEdge = liftIO . pinHasEdgeIO
  exportPin = liftIO . exportPinIO
  unexportPin = liftIO . unexportPinIO
  readPinDirection = liftIO . readPinDirectionIO
  writePinDirection p d = liftIO $ writePinDirectionIO p d
  writePinDirectionWithValue p v = liftIO $ writePinDirectionWithValueIO p v
  readPinValue = liftIO . readPinValueIO
  threadWaitReadPinValue = liftIO . threadWaitReadPinValueIO
  threadWaitReadPinValue' p to = liftIO $ threadWaitReadPinValueIO' p to
  writePinValue p v = liftIO $ writePinValueIO p v
  readPinEdge = liftIO . readPinEdgeIO
  writePinEdge p e = liftIO $ writePinEdgeIO p e
  readPinActiveLow = liftIO . readPinActiveLowIO
  writePinActiveLow p v = liftIO $ writePinActiveLowIO p v
  availablePins = liftIO availablePinsIO

-- 'MonadSysfs' implementation.

sysfsIsPresentIO :: IO Bool
sysfsIsPresentIO = doesDirectoryExist sysfsPath

pinIsExportedIO :: Pin -> IO Bool
pinIsExportedIO p = doesDirectoryExist (pinDirName p)

pinHasDirectionIO :: Pin -> IO Bool
pinHasDirectionIO p = doesFileExist (pinDirectionFileName p)

pinHasEdgeIO :: Pin -> IO Bool
pinHasEdgeIO p = doesFileExist (pinEdgeFileName p)

exportPinIO :: Pin -> IO ()
exportPinIO (Pin n) = IO.writeFile exportFileName (show n)

unexportPinIO :: Pin -> IO ()
unexportPinIO (Pin n) = IO.writeFile unexportFileName (show n)

readPinDirectionIO :: Pin -> IO PinDirection
readPinDirectionIO p =
  IOS.readFile (pinDirectionFileName p) >>= \case
    "in\n"  -> return In
    "out\n" -> return Out
    x     -> throwM $ UnexpectedDirection p x

writePinDirectionIO :: Pin -> PinDirection -> IO ()
writePinDirectionIO p d = IO.writeFile (pinDirectionFileName p) (lowercase $ show d)

writePinDirectionWithValueIO :: Pin -> PinValue -> IO ()
writePinDirectionWithValueIO p v = IO.writeFile (pinDirectionFileName p) (lowercase $ show v)

readPinValueIO :: Pin -> IO PinValue
readPinValueIO p =
  IOS.readFile (pinValueFileName p) >>= \case
    "0\n" -> return Low
    "1\n" -> return High
    x   -> throwM $ UnexpectedValue p x

threadWaitReadPinValueIO :: Pin -> IO PinValue
threadWaitReadPinValueIO p =
  threadWaitReadPinValueIO' p (-1) >>= \case
    Just v -> return v
    -- Yes, I really do mean "error" here. 'Nothing' can only occur
    -- when the poll has timed out, but the (-1) timeout value above
    -- means the poll must either wait forever or fail.
    Nothing -> error "threadWaitReadPinValueIO timed out, and it should not have. Please file a bug at https://github.com/dhess/gpio"

threadWaitReadPinValueIO' :: Pin -> Int -> IO (Maybe PinValue)
threadWaitReadPinValueIO' p timeout =
  do fd <- openFd (pinValueFileName p) ReadOnly Nothing defaultFileFlags
     pollResult <- throwErrnoIfMinus1Retry "pollSysfs" $ pollSysfs fd timeout
     -- Could use fdRead here and handle EAGAIN, but it's easier to
     -- close the fd and use nice handle-based IO, instead. If this
     -- becomes a performance problem... we probably need a
     -- non-sysfs-based interpreter in that case, anyway.
     closeFd fd
     if pollResult > 0
        then fmap Just $ readPinValueIO p
        else return Nothing

writePinValueIO :: Pin -> PinValue -> IO ()
writePinValueIO p v = IO.writeFile (pinValueFileName p) (toSysfsPinValue v)

readPinEdgeIO :: Pin -> IO SysfsEdge
readPinEdgeIO p =
  IOS.readFile (pinEdgeFileName p) >>= \case
    "none\n"  -> return None
    "rising\n" -> return Rising
    "falling\n" -> return Falling
    "both\n" -> return Both
    x     -> throwM $ UnexpectedEdge p x

writePinEdgeIO :: Pin -> SysfsEdge -> IO ()
writePinEdgeIO p v = IO.writeFile (pinEdgeFileName p) (toSysfsPinEdge v)

readPinActiveLowIO :: Pin -> IO Bool
readPinActiveLowIO p =
  IOS.readFile (pinActiveLowFileName p) >>= \case
    "0\n" -> return False
    "1\n" -> return True
    x   -> throwM $ UnexpectedActiveLow p x

writePinActiveLowIO :: Pin -> Bool -> IO ()
writePinActiveLowIO p v = IO.writeFile (pinActiveLowFileName p) (toSysfsActiveLowValue v)

availablePinsIO :: IO [Pin]
availablePinsIO =
  do sysfsEntries <- getDirectoryContents sysfsPath
     let sysfsContents = fmap (sysfsPath </>) sysfsEntries
     sysfsDirectories <- filterM doesDirectoryExist sysfsContents
     let chipDirs = filter (\f -> isPrefixOf "gpiochip" $ takeFileName f) sysfsDirectories
     pins <- mapM pinRange chipDirs
     return $ sort $ concat pins

-- Helper functions that aren't exported.
--

lowercase :: String -> String
lowercase = fmap toLower

toSysfsPinEdge :: SysfsEdge -> String
toSysfsPinEdge None = "none"
toSysfsPinEdge Rising = "rising"
toSysfsPinEdge Falling = "falling"
toSysfsPinEdge Both = "both"

toSysfsPinValue :: PinValue -> String
toSysfsPinValue Low = "0"
toSysfsPinValue High = "1"

toSysfsActiveLowValue :: Bool -> String
toSysfsActiveLowValue False = "0"
toSysfsActiveLowValue True = "1"

readIntFromFile :: FilePath -> IO Int
readIntFromFile f =
  do contents <- IOS.readFile f
     case readMaybe contents of
       Just n -> return n
       Nothing -> throwM $ UnexpectedContents f contents

chipBaseGpio :: FilePath -> IO Int
chipBaseGpio chipDir = readIntFromFile (chipDir </> "base")

chipNGpio :: FilePath -> IO Int
chipNGpio chipDir = readIntFromFile (chipDir </> "ngpio")

pinRange :: FilePath -> IO [Pin]
pinRange chipDir =
  do base <- chipBaseGpio chipDir
     ngpio <- chipNGpio chipDir
     case (base >= 0 && ngpio > 0) of
       False -> return []
       True -> return $ fmap Pin [base .. (base + ngpio - 1)]