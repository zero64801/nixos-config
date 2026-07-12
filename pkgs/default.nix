inputs: final: prev:
let
  inherit (prev) lib;

  packageFiles = lib.filesystem.listFilesRecursive ./packages;

  nixFiles = builtins.filter (f:
    let name = baseNameOf (toString f); in
    lib.hasSuffix ".nix" (toString f)
    && name != "flake.nix"
    && !lib.hasPrefix "_" name
  ) packageFiles;

  autoPackages = builtins.listToAttrs (map (f: {
    name = lib.removeSuffix ".nix" (baseNameOf (toString f));
    value = final.callPackage f { };
  }) nixFiles);

  functions = import ./functions.nix inputs final prev;
  overrides = import ./overrides.nix inputs final prev;

in
  autoPackages // functions // overrides
