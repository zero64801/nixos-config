{
  description = "NixOS Configuration";

  # Only what every host is built on. Whatever else a folder needs it declares itself, in its _inputs.nix, and core/inputs loads it.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      inherit (import ./hosts.nix { inherit inputs; }) nixosConfigurations;

      # nix build .#tests.FOLDER.NAME runs one test, and .#tests.all every one.
      legacyPackages = lib.genAttrs systems (system: {
        tests = import ./core/_tests/index.nix {
          flake = inputs.self;
          inherit system;
        };
      });

      # nix run .#inputs locks what the folders declare, each in the _inputs.lock beside its _inputs.nix.
      apps = lib.genAttrs systems (system: {
        inputs = {
          type = "app";
          program = lib.getExe (inputs.nixpkgs.legacyPackages.${system}.callPackage ./core/inputs/_lock.nix { });
        };
      });
    };
}
