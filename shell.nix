{ nixpkgs ? import <nixpkgs> {}, compiler ? "default" }:

let

  inherit (nixpkgs) pkgs;

  f = { mkDerivation, base, containers, errors, exceptions, free
      , hspec, mtl, stdenv, text, transformers
      }:
      mkDerivation {
        pname = "gpio";
        version = "0.0.0";
        src = ./.;
        libraryHaskellDepends = [
          base containers errors exceptions free mtl text transformers
        ];
        testHaskellDepends = [
          base containers errors exceptions free hspec mtl text transformers
        ];
        homepage = "https://github.com/dhess/gpio";
        description = "Control GPIO pins";
        license = stdenv.lib.licenses.bsd3;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  drv = haskellPackages.callPackage f {};

in

  if pkgs.lib.inNixShell then drv.env else drv