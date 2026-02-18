{ inputs }:

let
  lib = inputs.nixpkgs.lib;

  importDir = dir:
    let
      allFiles = lib.filesystem.listFilesRecursive dir;
      nixFiles = builtins.filter (f:
        let name = baseNameOf (toString f); in
        lib.hasSuffix ".nix" (toString f)
        && name != "flake.nix"
        && !lib.hasPrefix "_" name
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
