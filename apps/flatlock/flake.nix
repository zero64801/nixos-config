{
  description = "Declarative Flatpak state management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules.default = import ./default.nix;
      homeManagerModules.default = import ./_modules/home-manager.nix;

      checks.${system} = {
        eval = import ./_tests/eval.nix {
          inherit pkgs;
          nixosSystem = nixpkgs.lib.nixosSystem;
        };
        lint = pkgs.callPackage ./_tests/lint.nix { };
        lock-validation = pkgs.callPackage ./_tests/lock-validation.nix { };
        unit = pkgs.callPackage ./_tests/unit.nix { };
        vm = pkgs.testers.runNixOSTest (
          import ./_tests/vm.nix {
            homeManagerModule = home-manager.nixosModules.home-manager;
          }
        );
      };
    };
}
