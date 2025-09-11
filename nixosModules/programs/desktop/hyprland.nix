{
  pkgs,
  lib,
  config,
  ...
}: {
  options.nyx.desktop.hyprland.enable = lib.mkEnableOption "hyprland";
  config = lib.mkIf config.nyx.desktop.hyprland.enable {
    programs.hyprland.enable = true;

    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      brightnessctl
      fuzzel
      libnotify
      wayfreeze
      yazi
    ];
  };
}
