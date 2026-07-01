inputs: final: prev:
let
  inherit (prev) lib;

  overrideDir = ./overrides;

  hasOverrides = builtins.pathExists overrideDir;

  overrideFiles =
    if hasOverrides
    then
      let
        entries = builtins.readDir overrideDir;
        nixEntries = lib.filterAttrs (name: type:
          type == "regular" && lib.hasSuffix ".nix" name
        ) entries;
      in map (name: overrideDir + "/${name}") (builtins.attrNames nixEntries)
    else [];

  overrideSets = map (f: import f { inherit inputs final prev; }) overrideFiles;

in
  lib.foldl' lib.recursiveUpdate {} overrideSets
