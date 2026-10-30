{ inputs, hostName }: final: prev:
let
  inherit (prev) lib;

  isPackageFile = f:
    let name = baseNameOf (toString f); in
    lib.hasSuffix ".nix" (toString f)
    && name != "flake.nix"
    && !lib.hasPrefix "_" name;

  packagesFrom = dir:
    if !builtins.pathExists dir then { }
    else
      builtins.listToAttrs (map (f: {
        name = lib.removeSuffix ".nix" (baseNameOf (toString f));
        value = final.callPackage f { };
      }) (builtins.filter isPackageFile (lib.filesystem.listFilesRecursive dir)));

  overridesFrom = dir:
    if !builtins.pathExists dir then { }
    else
      lib.foldl' lib.recursiveUpdate { }
        (map (f: import f { inherit inputs final prev; })
          (builtins.filter isPackageFile (lib.filesystem.listFilesRecursive dir)));

  functions = import ./functions.nix inputs final prev;

  hostDir = ../hosts + "/${hostName}/_pkgs";
in
  packagesFrom ./packages
  // functions
  // packagesFrom (hostDir + "/packages")
  // overridesFrom (hostDir + "/overrides")
