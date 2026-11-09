{
  gui = {
    wayland = true;
    portals = true;
    sysfs = true;

    dbus.session = {
      talk = [ "org.freedesktop.Notifications" ];
      call = [ "org.freedesktop.portal.*=*" ];
      broadcast = [ "org.freedesktop.portal.*=@/org/freedesktop/portal/*" ];
    };

    binds.ro = [
      ".icons"
      ".themes"
      ".fonts"
      ".local/share/fonts"
      ".local/share/color-schemes"
      ".config/gtk-3.0"
      ".config/gtk-4.0"
      ".config/dconf"
      ".config/Kvantum"
      ".config/fontconfig"
    ];
  };

  gpu = {
    gpu = true;
    sysfs = true;
  };

  audio = {
    pipewire = true;
    pulse = true;
  };

  alsa.devices = [ "/dev/snd" ];

  compute.devices = [ "/dev/kfd" ];

  tray = {
    dbus.session.talk = [
      "org.kde.StatusNotifierWatcher"
      "com.canonical.AppMenu.Registrar"
      "com.canonical.indicator.application"
    ];
  };

  mpris.dbus.session.own = [ "org.mpris.MediaPlayer2.*" ];

  a11y.a11y = true;

  printing = {
    binds.ro = [ "/run/cups/cups.sock" ];
    env.CUPS_SERVER = "/run/cups/cups.sock";
  };

  # No org.freedesktop.secrets: the Secret Service hands every app's secrets to any client, so an app keeps its own key or uses the Secret portal, as Flatpak expects.
  chromium = {
    seccomp.nesting = true;
    dbus.session.talk = [ "org.freedesktop.ScreenSaver" ];
  };

  steam = {
    seccomp = {
      nesting = true;
      multiarch = true;
      bluetooth = true;
    };
    sysfs = true;
    devices = [
      "/dev/input"
      "/dev/hidraw*"
      "/dev/ntsync"
    ];
    dbus.session.talk = [ "org.freedesktop.ScreenSaver" ];
    dbus.system.talk = [ "org.freedesktop.UPower" ];
  };
}
