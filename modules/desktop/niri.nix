{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.desktop.niri;
  stylixCursorEnabled = (config.nyx.stylix.enable or false) && (config.nyx.stylix.cursor.enable or false);
  cursorPackage =
    if stylixCursorEnabled
    then config.nyx.stylix.cursor.package
    else pkgs.adwaita-icon-theme;
  cursorTheme =
    if stylixCursorEnabled
    then config.nyx.stylix.cursor.name
    else "Adwaita";
  cursorSize =
    if stylixCursorEnabled
    then toString config.nyx.stylix.cursor.size
    else "24";
  username = config.nyx.flake.user;
in
{
  options.nyx.desktop.niri.enable = lib.mkEnableOption "Niri Wayland compositor";

  config = lib.mkIf cfg.enable {
    programs.niri = {
      enable = true;
      useNautilus = false;
    };

    programs.dms-shell = {
      enable = true;
      systemd.enable = false;
      enableDynamicTheming = false;
    };

    services.displayManager.sddm.enable = lib.mkForce false;
    services.displayManager.autoLogin.enable = lib.mkForce false;
    services.gnome.gcr-ssh-agent.enable = lib.mkForce false;
    services.gvfs.enable = true;
    services.udisks2.enable = true;

    xdg.portal.config.niri."org.freedesktop.impl.portal.FileChooser" = "gtk";

    services.getty = {
      autologinUser = username;
      autologinOnce = true;
    };

    environment.loginShellInit = ''
      if [ "''${USER:-}" = "${username}" ] && [ "$(tty)" = /dev/tty1 ] && [ -z "''${WAYLAND_DISPLAY:-}" ] && [ -z "''${DISPLAY:-}" ] && [ -z "''${NIRI_SOCKET:-}" ] && [ -z "''${NYX_NIRI_AUTOSTARTED:-}" ]; then
        nyx_niri_lock="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/nyx-niri-autostart.lock"
        if mkdir "$nyx_niri_lock" 2>/dev/null; then
          trap 'rmdir "$nyx_niri_lock" 2>/dev/null' EXIT
          export NYX_NIRI_AUTOSTARTED=1
          ${lib.getExe' config.programs.niri.package "niri-session"} -l
          rmdir "$nyx_niri_lock" 2>/dev/null
          exit
        fi
      fi
    '';

    environment.sessionVariables = {
      XCURSOR_THEME = cursorTheme;
      XCURSOR_SIZE = cursorSize;
      DMS_DISABLE_MATUGEN = "1";
    };

    environment.systemPackages = with pkgs; [
      alacritty
      brightnessctl
      cursorPackage
      playerctl
      slurp
      swaylock
      wev
      xwayland-satellite
    ];
  };
}
