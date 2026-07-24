{ inputs, hostName }: final: prev:
let
  inherit (prev) lib;

  isPackageFile = f:
    let name = baseNameOf (toString f); in
    lib.hasSuffix ".nix" (toString f)
    && name != "flake.nix"
    && !lib.hasPrefix "_" name;

  # Additive packages: callPackage every non-underscore *.nix under `dir`,
  # keyed by filename. Missing dir yields nothing.
  packagesFrom = dir:
    if !builtins.pathExists dir then { }
    else
      builtins.listToAttrs (map (f: {
        name = lib.removeSuffix ".nix" (baseNameOf (toString f));
        value = final.callPackage f { };
      }) (builtins.filter isPackageFile (lib.filesystem.listFilesRecursive dir)));

  # Overrides: import each `{ inputs, final, prev }` file and merge. These
  # mutate existing packages, so they are only ever applied for the host that
  # owns them - never globally.
  overridesFrom = dir:
    if !builtins.pathExists dir then { }
    else
      let
        entries = lib.filterAttrs
          (name: type:
            type == "regular" && lib.hasSuffix ".nix" name && !lib.hasPrefix "_" name)
          (builtins.readDir dir);
        files = map (name: dir + "/${name}") (builtins.attrNames entries);
      in
      lib.foldl' lib.recursiveUpdate { }
        (map (f: import f { inherit inputs final prev; }) files);

  functions = import ./functions.nix inputs final prev;

  # A host's bespoke packages/overrides live inside its own directory
  # (hosts/<name>/_pkgs), so the whole host is one self-contained, deletable
  # unit. The `_` prefix keeps importDir from treating them as NixOS modules.
  hostDir = ../hosts + "/${hostName}/_pkgs";
in
  packagesFrom ./packages
  // functions
  // packagesFrom (hostDir + "/packages")
  // overridesFrom (hostDir + "/overrides")
