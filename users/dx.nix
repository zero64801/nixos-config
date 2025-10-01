{ config,
  lib,
  pkgs,
  ...
}:
let
  username = "dx";
  description = "dx";
in {
  nyx.data.users = [username];

  users.users.${username} = {
    inherit description;

    shell = pkgs.fish;
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ] ++ config.nyx.security.serviceAdminGroups;
    hashedPasswordFile = "/persist/local/secrets/passwd/dx";

    # only declare common packages here
    # others: hosts/<hostname>/user-configuration.nix
    # if you declare something here that isn't common to literally every host I
    # will personally show up under your bed whoever and wherever you are
    packages = with pkgs; [
      vim
      wget
      curl
      git
      fastfetch
      micro
    ];
  };

  home-manager.users.${username} = {
    home.stateVersion = lib.mkDefault config.system.stateVersion;
  };
}
