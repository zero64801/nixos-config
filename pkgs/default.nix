inputs: final: prev:
let
  inherit (prev) lib callPackage;

  # Auto-discover packages
  packages = lib.filesystem.listFilesRecursive ./packages;

  nixFiles = builtins.filter (f:
    lib.hasSuffix ".nix" (toString f)
  ) packages;

  autoPackages = builtins.listToAttrs (map (f: {
    name = lib.removeSuffix ".nix" (baseNameOf (toString f));
    value = callPackage f { };
  }) nixFiles);

  functions = import ./functions.nix inputs final prev;
in
  autoPackages // functions
