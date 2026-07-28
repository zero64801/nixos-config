{ config, lib, pkgs, ... }:

let
  gamescopeRt = config.nyx.apps.gaming.gamescopeRt;
  library = "/mnt/vault/Games/Steam";
in
# Without the guard the wrapper, persistence dir and warning exist with Steam disabled.
lib.mkIf config.nyx.apps.gaming.steam.enable {
  # install = false, programs.steam itself puts the package in the system profile.
  nyx.confine.apps.steam = {
    package = pkgs.steam;
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

    # Discord rich presence and speech-dispatcher need runtime paths binds cannot express.
  };

  # The wrapper re-confines programs.steam's compatibility tool override.
  programs.steam.package = config.nyx.confine.packages.steam;
}
