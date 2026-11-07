{ inputs, hostName, lib, pkgs, ... }:

{
  nixpkgs = {
    config.allowUnfree = true;
    overlays = [ (import ../pkgs/default.nix { inherit inputs hostName; }) ];
  };

  nix = {
    package = pkgs.lixPackageSets.lix_2_96.lix;
    channel.enable = false;

    settings = {
      experimental-features = [ "nix-command" "flakes" "pipe-operator" ];
      extra-deprecated-features = [ "or-as-identifier" ];

      substituters = [ "https://nix-community.cachix.org" ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };

    gc = {
      persistent = true;
      automatic = lib.mkDefault true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };
}
