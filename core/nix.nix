{ lib, pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  nix = {
    package = pkgs.lixPackageSets.lix_2_96.lix;
    channel.enable = false;

    settings = {
      experimental-features = [ "nix-command" "flakes" "pipe-operator" ];
      extra-deprecated-features = [ "or-as-identifier" ];
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
