{ config, lib, pkgs, ... }:

let
  cfg = config.my.desktop.niri;
  stylixCursorEnabled = (config.my.stylix.enable or false) && (config.my.stylix.cursor.enable or false);
  cursorPackage =
    if stylixCursorEnabled
    then config.my.stylix.cursor.package
    else pkgs.adwaita-icon-theme;
  cursorTheme =
    if stylixCursorEnabled
    then config.my.stylix.cursor.name
    else "Adwaita";
  cursorSize =
    if stylixCursorEnabled
    then toString config.my.stylix.cursor.size
    else "24";
  username = config.my.flake.user;
in
{
  options.my.desktop.niri.enable = lib.mkEnableOption "Niri Wayland compositor";

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
      if [ "''${USER:-}" = "${username}" ] && [ "$(tty)" = /dev/tty1 ] && [ -z "''${WAYLAND_DISPLAY:-}" ] && [ -z "''${DISPLAY:-}" ] && [ -z "''${NIRI_SOCKET:-}" ] && [ -z "''${MY_NIRI_AUTOSTARTED:-}" ]; then
        my_niri_lock="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/my-niri-autostart.lock"
        if mkdir "$my_niri_lock" 2>/dev/null; then
          trap 'rmdir "$my_niri_lock" 2>/dev/null' EXIT
          export MY_NIRI_AUTOSTARTED=1
          ${lib.getExe' config.programs.niri.package "niri-session"} -l
          rmdir "$my_niri_lock" 2>/dev/null
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
