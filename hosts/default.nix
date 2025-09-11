{
  sources,
  lib,
}: let
  inherit (lib) attrValues genAttrs;
  overlays = attrValues {
    sources = final: prev: {inherit sources;};
    lix = import ../pkgs/overlays/lix.nix {lix = null;};
    internal = import ../pkgs/overlays/internal.nix;
    package-overrides = import ../pkgs/overlays/package-overrides.nix;
    chaotic = import (sources.chaotic + "/overlays") { flakes = sources; };
    nur = final: prev: {
      nur = import sources.nur {
        pkgs = final;
      };
    };
  };
  nixosSystem = import (sources.nixpkgs + "/nixos/lib/eval-config.nix");
  mkHost = hostName:
    nixosSystem {
      system = null;
      specialArgs = {inherit sources;};
      modules = [
        {nixpkgs.overlays = overlays;}
        (sources.home-manager + "/nixos")
        ./${hostName}/configuration.nix
        ../nixosModules
      ];
    };

  hosts = [ "Quanta" "Silverwing" ];
in
  genAttrs hosts mkHost
