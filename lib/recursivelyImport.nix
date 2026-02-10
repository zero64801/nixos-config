{ lib }:

let
  inherit (lib) concatMap hasSuffix hasPrefix;
  inherit (builtins) isPath filter readFileType baseNameOf;

  expandIfFolder = elem:
    if !isPath elem || readFileType elem != "directory"
      then [ elem ]
    else lib.filesystem.listFilesRecursive elem;

in
  list: filter
    (elem:
      let
        pathStr = toString elem;
        name = baseNameOf pathStr;
      in
      (!isPath elem || hasSuffix ".nix" pathStr) &&
      !(hasPrefix "_" name) &&
      name != "flake.nix"
    )
    (concatMap expandIfFolder list)
