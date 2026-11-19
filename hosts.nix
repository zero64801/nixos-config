{ inputs }:

let
  lib = inputs.nixpkgs.lib;

  importDir = dir:
    let
      allFiles = lib.filesystem.listFilesRecursive dir;
      relParts = f: lib.splitString "/" (lib.removePrefix (toString dir + "/") (toString f));
      nixFiles = builtins.filter (f:
        let name = baseNameOf (toString f); in
        lib.hasSuffix ".nix" (toString f)
        && name != "flake.nix"
        && !lib.any (lib.hasPrefix "_") (relParts f)
      ) allFiles;
    in nixFiles;

  shared = importDir ./core ++ importDir ./apps ++ importDir ./modules;

  hostnames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
  );

  specialArgs = hostName: { inherit inputs hostName; };

  system = hostName: modules:
    lib.nixosSystem {
      specialArgs = specialArgs hostName;
      inherit modules;
    };

in
{
  # The modules every host gets and how a system is made of them, for whatever builds a system that is no host here, as the tests do.
  inherit shared specialArgs system;

  nixosConfigurations = lib.genAttrs hostnames (hostname: system hostname (shared ++ importDir ./hosts/${hostname}));
}
