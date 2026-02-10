{ inputs }:

let
  lib = inputs.nixpkgs.lib;

  recursivelyImport = import ./lib/recursivelyImport.nix { inherit lib; };

  hostnames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
  );

  mkSystem = hostname:
    lib.nixosSystem {
      specialArgs = { inherit inputs; };

      modules = recursivelyImport [
        ./base
        ./apps
        ./desktop
        ./hardware
        ./modules
        ./hosts/${hostname}
      ] ++ [
        inputs.lix-module.nixosModules.default
      ];
    };

in
  lib.genAttrs hostnames mkSystem
