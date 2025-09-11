{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.nyx.desktop.niri = {
    enable = lib.mkEnableOption "the Niri WM and its configuration";
  };

  config = lib.mkIf config.nyx.desktop.niri.enable {
    programs.niri.enable = true;

    environment.systemPackages = with pkgs; [
      alacritty
      wl-clipboard
      grim
      brightnessctl
      libnotify
      fuzzel
      swaybg
    ];
  };
}
