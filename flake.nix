{
	description = "My system configuration";

	inputs = {
		nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
		
		home-manager = {
			url = "github:nix-community/home-manager";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = { nixpkgs, home-manager, ... }@inputs:
		let
			system = "x86_64-linux";
		in {
		nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
			inherit system;
			modules = [
                ./nixos/configuration.nix
            ];
		};

		homeConfigurations.teto = home-manager.lib.homeManagerConfiguration {
			pkgs = import nixpkgs { inherit system; };  #nixpkgs.legacyPackages.${system};
			extraSpecialArgs = { inherit inputs; };
			modules = [
                ./home-manager/home.nix
            ];
		};
	};
}
