{ config, lib, pkgs, ... }:

let
  gamescopeRt = config.nyx.apps.gaming.gamescopeRt;
  library = "/mnt/vault/Games/Steam";

  portalOpen = lib.getExe' pkgs.flatpak-xdg-utils "xdg-open";

  /*
  "Browse local files" and external links go through Steam's own FHS
  /usr/bin/xdg-open (real xdg-utils), which resolves the xdg-mime default handler
  and execs it, launching a file manager or browser inside the sandbox where a
  single-instance handoff over the filtered bus crashes it. Rather than shadow
  each file manager by name, this redefines the default handler for directories
  and web links to one that calls the OpenURI portal, so the host opens them.
  Named nothing app-specific, so any file manager works. mimeapps.list is placed
  both plain and desktop-prefixed to win regardless of lookup precedence. The
  confine PATH cannot reach the inner FHS, so the override lands in its profile.
  */
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
# Without the guard the wrapper, persistence dir and warning exist with Steam disabled.
lib.mkIf config.nyx.apps.gaming.steam.enable {
  # install = false, programs.steam itself puts the package in the system profile.
  nyx.confine.apps.steam = {
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

    # Remote Play and local transfers need the real LAN, "isolated" breaks them.
    network = "host";

    # Steam is X11 only. "host" lets KWin manage game windows directly, like Flatpak.
    # "isolated" (xwayland-satellite) breaks game fullscreen and window icons.
    x11 = "host";

    binds = {
      rw = [
        library
        # Socket connect needs the rw bind.
        gamescopeRt.socketPath

        # Real path so the stylix CSS adwsteamgtk injects into steamui/ is seen.
        # .local/share/vulkan stays out, an implicit layer loads into every GPU app.
        ".local/share/Steam"
        ".steam"
      ];
      ro = [
        ".config/MangoHud"
        # libudev needs it for controller hotplug enumeration.
        "/run/udev"
      ];
    };

    # Without this gamemoderun silently does nothing.
    dbus.session.talk = [
      "com.feralinteractive.GameMode"
      # Sleep and screen-blank inhibition, ScreenSaver comes from the steam profile.
      "org.freedesktop.PowerManagement"
      "org.gnome.SessionManager"
    ];

    # Steam publishes under com.steampowered, not under its application id.
    dbus.session.own = [ "com.steampowered.*" ];

    # libdbus aborts on some protocol warnings, a filtered bus makes those likelier.
    env.DBUS_FATAL_WARNINGS = "0";

    # SDL's udev hotplug monitor does not deliver inside a user namespace.
    # This picks the inotify fallback, the same path SDL auto-selects under Flatpak.
    env.SDL_JOYSTICK_DISABLE_UDEV = "1";

  };

  # The wrapper re-confines programs.steam's compatibility tool override.
  programs.steam.package = config.nyx.confine.packages.steam;
}
