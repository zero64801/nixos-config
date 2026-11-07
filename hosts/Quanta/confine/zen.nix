{ config, lib, ... }:

lib.mkIf config.my.apps.zen.enable {
  my.confine.apps.zen = {
    package = config.hm.programs.zen-browser.finalPackage;
    appId = "app.zen_browser.zen";
    install = false;
    keepDesktopNames = true;

    profile = [
      "gui"
      "gpu"
      "audio"
      "mpris"
    ];

    seccomp.nesting = true;

    extraBwrapArgs =
      lib.concatMap (node: [ "--ro-bind" "/dev/null" node ]) [
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
      ]
      ++ [ "--tmpfs" "/dev/nvidia-caps" ];

    network = "isolated";
    networkPorts.toHost = [
      3000
      8000
    ];

    devices = [ "/dev/input/by-id/*-fido" ];

    dbus.session = {
      own = [ "org.mozilla.zen.*" ];
      talk = [
        "org.freedesktop.ScreenSaver"
        "org.freedesktop.FileManager1"
      ];
    };

    binds.rw = [
      ".config/zen"
      "Downloads"
    ];
  };

  my.apps.zen.profileSettings = {
    "widget.use-xdg-desktop-portal.file-picker" = 1;
    "widget.use-xdg-desktop-portal.mime-handler" = 1;
    "widget.use-xdg-desktop-portal.open-uri" = 1;
  };

  hm.home.packages = [ (lib.hiPrio config.my.confine.packages.zen) ];
}
