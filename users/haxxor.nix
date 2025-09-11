{ config,
  lib,
  pkgs,
  ...
}:
let
  username = "haxxor";
  description = "haxxor";
in {
  nyx.data.users = [username];

  users.users.${username} = {
    inherit description;

    shell = pkgs.fish;
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" "multimedia" ];
    hashedPasswordFile = "/persist/local/secrets/passwd/haxxor";

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
