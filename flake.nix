{
  description = "NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence.url = "github:nix-community/impermanence";
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      # System builder function
      mkSystem = hostname: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        specialArgs = {
          inherit inputs;
        };

        modules = [
          # Host-specific configuration
          ./hosts/${hostname}

          # NixOS modules
          ./modules/nixos

          # External modules
          inputs.home-manager.nixosModules.home-manager
          inputs.impermanence.nixosModules.impermanence
          inputs.disko.nixosModules.disko

          # Global configuration
          {
            nixpkgs.overlays = [
              inputs.nur.overlays.default
            ];
          }
          ({ config, ... }: {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = {
                inherit inputs;
                stateVersion = config.system.stateVersion;
              };
            };
          })
        ];
      };

      # Auto-discover hosts from directory
      hostnames = builtins.attrNames (
        nixpkgs.lib.filterAttrs
          (_name: type: type == "directory")
          (builtins.readDir ./hosts)
      );
    in
    {
      # NixOS configurations
      nixosConfigurations = nixpkgs.lib.genAttrs hostnames mkSystem;

      # Expose packages for external use (optional)
      overlays.default = inputs.nur.overlays.default;
    };
}
