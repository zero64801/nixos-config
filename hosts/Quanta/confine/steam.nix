{ config, lib, pkgs, ... }:

let
  gamescopeRt = config.my.apps.gaming.gamescopeRt;
  library = "/mnt/vault/Games/Steam";

  portalOpen = lib.getExe' pkgs.flatpak-xdg-utils "xdg-open";

  confineOpenDesktop = pkgs.writeText "confine-open.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Open on host
    Exec=${portalOpen} %U
    MimeType=inode/directory;x-scheme-handler/http;x-scheme-handler/https;
    NoDisplay=true
  '';

  mimeappsList = pkgs.writeText "mimeapps.list" ''
    [Default Applications]
    inode/directory=confine-open.desktop
    x-scheme-handler/http=confine-open.desktop
    x-scheme-handler/https=confine-open.desktop
  '';

  portalHandler = pkgs.runCommandLocal "steam-portal-handler" { } ''
    mkdir -p "$out/share/applications" "$out/etc/xdg"
    cp ${confineOpenDesktop} "$out/share/applications/confine-open.desktop"
    cp ${mimeappsList} "$out/etc/xdg/mimeapps.list"
    cp ${mimeappsList} "$out/etc/xdg/kde-mimeapps.list"
  '';

  steamWithPortalOpen = pkgs.steam.override {
    extraProfile = ''
      export XDG_DATA_DIRS=${portalHandler}/share:$XDG_DATA_DIRS
      export XDG_CONFIG_DIRS=${portalHandler}/etc/xdg:$XDG_CONFIG_DIRS
    '';
  };
in
lib.mkIf config.my.apps.gaming.steam.enable {
  my.confine.apps.steam = {
    package = steamWithPortalOpen;
    appId = "com.valvesoftware.Steam";
    install = false;

    profile = [
      "gui"
      "gpu"
      "audio"
      "tray"
      "steam"
    ];

    network = "isolated";

    x11 = "host";

    binds = {
      rw = [
        library
        gamescopeRt.socketPath

        ".local/share/Steam"
        ".steam"
      ];
      ro = [
        ".config/MangoHud"
        "/run/udev"
      ];
    };

    dbus.session.talk = [
      "com.feralinteractive.GameMode"
      "org.freedesktop.PowerManagement"
      "org.gnome.SessionManager"
    ];

    dbus.session.own = [ "com.steampowered.*" ];

    env.DBUS_FATAL_WARNINGS = "0";

    env.SDL_JOYSTICK_DISABLE_UDEV = "1";

  };

  programs.steam.package = config.my.confine.packages.steam;
}
