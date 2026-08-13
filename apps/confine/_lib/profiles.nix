# Profile lists are additive, they concatenate with app-declared lists.
{
  gui = {
    wayland = true;
    portals = true;
    # Input and card enumeration go through libudev, which reads sysfs.
    sysfs = true;

    dbus.session = {
      # Portal names get the call rule below, talk is broader.
      # Notifications is not a portal name.
      # portal.Flatpak is a Spawn primitive and stays out.
      talk = [ "org.freedesktop.Notifications" ];
      # Portal replies arrive as Response signals, without broadcast every request hangs.
      call = [ "org.freedesktop.portal.*=*" ];
      broadcast = [ "org.freedesktop.portal.*=@/org/freedesktop/portal/*" ];
    };

    # The private home has none of the host theming, bound back read-only.
    binds.ro = [
      ".icons"
      ".themes"
      ".fonts"
      ".local/share/fonts"
      ".local/share/color-schemes"
      ".config/gtk-3.0"
      ".config/gtk-4.0"
      ".config/Kvantum"
      ".config/fontconfig"
    ];
  };

  # sysfs is needed to resolve a card node to its PCI device.
  gpu = {
    gpu = true;
    sysfs = true;
  };

  # The pulse socket is also unmediated microphone access, as with Flatpak.
  audio = {
    pipewire = true;
    pulse = true;
  };

  # /dev/snd includes the capture devices, unmediated microphone access.
  alsa.devices = [ "/dev/snd" ];

  # ROCm compute node, rendering does not need it.
  compute.devices = [ "/dev/kfd" ];

  # xdg-dbus-proxy rejects wildcards not preceded by a dot, so the per-pid item name cannot be matched.
  # Registration only needs the watcher.
  tray = {
    dbus.session.talk = [
      "org.kde.StatusNotifierWatcher"
      "com.canonical.AppMenu.Registrar"
      "com.canonical.indicator.application"
    ];
  };

  # The appId MPRIS name is granted automatically, this covers unrelated names.
  mpris.dbus.session.own = [ "org.mpris.MediaPlayer2.*" ];

  # The a11y bus carries keystrokes, so it is opt-in rather than part of gui.
  a11y.a11y = true;

  # libcups looks under /var/run, which the sandbox does not have.
  printing = {
    binds.ro = [ "/run/cups/cups.sock" ];
    env.CUPS_SERVER = "/run/cups/cups.sock";
  };

  # The zygote sandbox needs a nested userns, denying it forces --no-sandbox.
  chromium = {
    seccomp.nesting = true;
    dbus.session.talk = [
      "org.freedesktop.ScreenSaver"
      "org.freedesktop.secrets"
    ];
  };

  # pressure-vessel nests containers.
  # Without the second arch token the filter never applies to Steam's 32-bit binaries.
  steam = {
    seccomp = {
      nesting = true;
      multiarch = true;
      bluetooth = true;
    };
    sysfs = true;
    devices = [
      # uinput would let the sandbox synthesize input into the host.
      "/dev/input"
      # Security keys also speak raw HID and are exposed by this grant.
      "/dev/hidraw*"
      # Without ntsync Proton falls back to the slower esync/fsync paths.
      "/dev/ntsync"
    ];
    dbus.session.talk = [ "org.freedesktop.ScreenSaver" ];
    dbus.system.talk = [ "org.freedesktop.UPower" ];
  };
}
