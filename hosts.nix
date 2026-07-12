{ inputs }:

let
  lib = inputs.nixpkgs.lib;

  importDir = dir:
    let
      allFiles = lib.filesystem.listFilesRecursive dir;
      # _ escapes the auto-importer for whole directories, not just files.
      relParts = f: lib.splitString "/" (lib.removePrefix (toString dir + "/") (toString f));
      nixFiles = builtins.filter (f:
        let name = baseNameOf (toString f); in
        lib.hasSuffix ".nix" (toString f)
        && name != "flake.nix"
        && !lib.any (lib.hasPrefix "_") (relParts f)
      ) allFiles;
    in nixFiles;

  hostnames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
  );

  mkSystem = hostname:
    lib.nixosSystem {
      specialArgs = { inherit inputs; };

      modules =
        importDir ./core
        ++ importDir ./apps
        ++ importDir ./modules
        ++ importDir ./hosts/${hostname}
        ++ [
          inputs.lix-module.nixosModules.default
        ];
    };

in
  lib.genAttrs hostnames mkSystem
