let
  compiler-nix-name = "ghc927";
  # Read in the Niv sources
  sources = import ./nix/sources.nix { };
  # If ./nix/sources.nix file is not found run:
  #   niv init
  #   niv add input-output-hk/haskell.nix -n haskellNix

  # Fetch the haskell.nix commit we have pinned with Niv
  haskellNix = import sources.haskellNix { };
  # If haskellNix is not found run:
  #   niv add input-output-hk/haskell.nix -n haskellNix

  nixpkgsArgs = haskellNix.nixpkgsArgs // {
    overlays = haskellNix.nixpkgsArgs.overlays ++ [
    ];
  };

  # Import nixpkgs and pass the haskell.nix provided nixpkgsArgs
  pkgs = (import
    # haskell.nix provides access to the nixpkgs pins which are used by our CI,
    # hence you will be more likely to get cache hits when using these.
    # But you can also just use your own, e.g. '<nixpkgs>'.
    haskellNix.sources.nixpkgs-unstable
    # These arguments passed to nixpkgs, include some patches and also
    # the haskell.nix functionality itself as an overlay.
    #index-state = "2019-07-14T00:00:00Z"; 
    nixpkgsArgs);
  ##    base4143 = (haskell-nix.hackage-package { 
  ##      name = "base";
  ##      version = "4.14.3"; 
  ##      compiler-nix-name = compiler-nix-name; }).components.library;
  ##    base4143 = (haskell-nix.hackage-package { 
  ##      name = "base";
  ##      version = "4.14.3"; 
  ##      compiler-nix-name = compiler-nix-name; }).components.library;
in
pkgs.haskell-nix.project
{
  # 'cleanGit' cleans a source directory based on the files known by git
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "hpio";
    src = ./.;
  };
  # Specify the GHC version to use.
  compiler-nix-name = compiler-nix-name; # Not required for `stack.yaml` based projects.
}
