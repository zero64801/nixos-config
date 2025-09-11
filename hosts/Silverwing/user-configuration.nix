{
  config,
  lib,
  pkgs,
  dconf,
  ...
}: let
  packages = lib.attrValues {
  };
in {
  users.users."haxxor" = {
    inherit packages;
    extraGroups = [];
  };

  services.pcscd.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  home-manager.users."haxxor" = {
    imports = [ ./apps ];

    programs.niri.wallpaperPath = ./dots/wallpaper.png;

    programs.git = {
      enable = true;

      userName = "haxxor";
      userEmail = "haxxor@example.com";

      extraConfig = {
        safe.directory = "/system-flake";
      };
    };
  };
}
