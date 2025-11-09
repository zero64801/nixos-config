{
  pkgs,
  lib,
  config,
  ...
}:
{
  options.nyx.desktop.cosmic.enable = lib.mkEnableOption "COSMIC desktop environment";
  config = lib.mkIf config.nyx.desktop.cosmic.enable {
    services = {
      # COSMIC Desktop Environment
      desktopManager.cosmic = {
        enable = true;
        xwayland.enable = true;
      };
      displayManager.cosmic-greeter.enable = true;

      # Desktop services
      gnome.gnome-keyring.enable = true;
      gnome.gnome-settings-daemon.enable = true;
      gvfs.enable = true;
    };

    # COSMIC-focused application packages
    environment.systemPackages = with pkgs; [
      # Essential COSMIC utilities
      cosmic-ext-ctl
      cosmic-ext-tweaks
      cosmic-ext-calculator
      cosmic-ext-applet-caffeine

      # Nemo file manager and extensions
      nemo
      nemo-with-extensions
      nemo-python
      nemo-preview
      nemo-seahorse
      nemo-fileroller

      # GNOME programs
      file-roller
      gnome-control-center
      gnome-settings-daemon
      gnome-tweaks
      xdg-user-dirs-gtk

      # Wayland
      wl-clipboard
      xwayland
      wayland-utils
    ];

    # XDG portals for COSMIC
    xdg.portal = {
      enable = true;
      wlr.enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal
        xdg-desktop-portal-cosmic
        xdg-desktop-portal-gtk
      ];
      config.common.default = "cosmic";
    };

    # COSMIC-specific environment variables
    environment.sessionVariables = {
      # COSMIC-specific
      COSMIC_DATA_CONTROL_ENABLED = "1";

      # Qt settings
      QT_QPA_PLATFORMTHEME = "gtk3";
      QT_STYLE_OVERRIDE = "breeze";
      QT_WAYLAND_DECORATION = "adwaita";
      QT_AUTO_SCREEN_SCALE_FACTOR = "1";

      # Wayland
      GDK_SCALE = "1.25";
      MOZ_ENABLE_WAYLAND = "1";
      MOZ_WEBRENDER = "1";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      _JAVA_AWT_WM_NONREPARENTING = "1";
    };
  };
}
