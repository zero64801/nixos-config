{ lib, pkgs, ... }:

{
  imports = [
    ./system
    ./hardware
    ./programs
  ];

  options = {
    nyx.data.headless = lib.mkEnableOption "headless mode (disables GUI components)";
  };

  config = {
    nixpkgs.config.allowUnfree = true;

    nix = {
      package = pkgs.lix;
      channel.enable = false;

      settings = {
        experimental-features = [ "nix-command" "flakes" ];
        auto-optimise-store = true;

        trusted-users = [ "root" "@wheel" ];

        substituters = [ "https://nix-community.cachix.org" ];

        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };

      gc = {
        persistent = true;
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
      };
    };
  };
}
