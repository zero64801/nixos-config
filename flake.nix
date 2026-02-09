{
  description = "NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    impermanence.url = "github:nix-community/impermanence";
    disko.url = "github:nix-community/disko";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      # System builder function
      mkSystem =
        hostname:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";

          specialArgs = {
            inherit inputs;
          };

          modules = [
            # Host-specific configuration
            ./hosts/${hostname}

            # NixOS modules
            ./modules

            # External modules
            inputs.home-manager.nixosModules.home-manager
            inputs.impermanence.nixosModules.impermanence
            inputs.disko.nixosModules.disko

            # Global configuration
            {
              nixpkgs.overlays = [
                (import ./overlays/default.nix)
              ];
            }
            (
              { config, pkgs, ... }:
              {
                home-manager = {
                  useGlobalPkgs = true;
                  useUserPackages = true;
                  backupCommand = "${pkgs.coreutils}/bin/mv --backup=numbered";
                  sharedModules = [ inputs.plasma-manager.homeModules.plasma-manager ];
                  extraSpecialArgs = {
                    inherit inputs;
                    stateVersion = config.system.stateVersion;
                  };
                };
              }
            )
          ];
        };

      # Auto-discover hosts from directory
      hostnames = builtins.attrNames (
        nixpkgs.lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./hosts)
      );
    in
    {
      # NixOS configurations
      nixosConfigurations = nixpkgs.lib.genAttrs hostnames mkSystem;
    };
}
