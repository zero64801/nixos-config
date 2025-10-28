{
  pkgs,
  lib,
  config,
  ...
}: {
  options.nyx.desktop.kde.enable = lib.mkEnableOption "Plasma desktop environment";
  config = lib.mkIf config.nyx.desktop.kde.enable {
    services = {
      displayManager.sddm.enable = true;
      displayManager.sddm.wayland.enable = true;
      desktopManager.plasma6.enable = true;
    };

    environment.systemPackages = with pkgs; [
        # KDE
        kdePackages.discover # Optional: Install if you use Flatpak or fwupd firmware update sevice
        kdePackages.kcalc # Calculator
        kdePackages.kcharselect # Tool to select and copy special characters from all installed fonts
        kdePackages.kclock # Clock app
        kdePackages.kcolorchooser # A small utility to select a color
        kdePackages.kolourpaint # Easy-to-use paint program
        kdePackages.ksystemlog # KDE SystemLog Application
        kdePackages.sddm-kcm # Configuration module for SDDM
        # Non-KDE graphical packages
        wayland-utils # Wayland utilities
        wl-clipboard # Command-line copy/paste utilities for Wayland
    ];
  };
}
