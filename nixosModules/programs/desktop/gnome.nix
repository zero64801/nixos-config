{
  pkgs,
  lib,
  config,
  ...
}: {
  options.nyx.desktop.gnome.enable = lib.mkEnableOption "GNOME desktop environment";
  config = lib.mkIf config.nyx.desktop.gnome.enable {
    services = {
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
    };

    environment.systemPackages = with pkgs; [
      wl-clipboard
      gnome-terminal
      gnome-tweaks
      gnome-extension-manager
      gnomeExtensions.user-themes
      gnomeExtensions.appindicator
      gnomeExtensions.dash-to-dock
      gnomeExtensions.clipboard-indicator
      gnomeExtensions.hide-activities-button
      gnomeExtensions.caffeine
      gnomeExtensions.overview-background
    ];

    environment.gnome.excludePackages = with pkgs; [
      cheese eog epiphany simple-scan totem
      yelp geary evince decibels baobab seahorse
      gnome-calendar gnome-characters gnome-contacts
      gnome-font-viewer gnome-logs gnome-maps gnome-music
      gnome-connections gnome-tour snapshot gnome-console
      gnome-software gnome-photos gnome-disk-utility
      gnome-secrets gnome-pass-search-provider
      gnome-weather gnome-clocks
    ];

    services.xserver.excludePackages = [ pkgs.xterm ];
  };
}
