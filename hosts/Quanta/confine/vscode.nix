{ lib, pkgs, ... }:

let
  devHome = "/home/dx/Projects/dev/.home";
  vinegar = "/home/dx/.var/app/org.vinegarhq.Vinegar/data/vinegar";

  workspace = {
    profile = [ "gpu" ];
    wayland = true;
    portals = true;
    sysfs = true;

    home = "ephemeral";
    runtimeDir = "shared";
    network = "isolated";

    seccomp = {
      nesting = true;
      devel = true;
    };

    extraBwrapArgs =
      lib.concatMap (node: [ "--ro-bind" "/dev/null" node ]) [
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
      ]
      ++ [
        "--tmpfs"
        "/dev/nvidia-caps"
        "--dir"
        "/run/systemd/system"
      ];

    env = {
      HOME = devHome;
      NIX_REMOTE = "daemon";
      NH_ELEVATION_STRATEGY = "run0";
    };
    envPassthrough = [ "NIX_PATH" ];

    binds.rw = [
      "/home/dx/nixos"
      "/home/dx/Projects"
    ];
    binds.ro = [
      "/nix/var/nix/daemon-socket"
      "/lib64"
      "${vinegar}/versions"
      "${vinegar}/kombucha"
      "/home/dx/Projects/dev/.envrc"
      "/home/dx/Projects/dev/shell.nix"
    ];
    gitGuard.enable = true;

    dbus.session = {
      talk = [ "org.freedesktop.Notifications" ];
      call = [ "org.freedesktop.portal.Desktop=org.freedesktop.portal.OpenURI.*@/org/freedesktop/portal/desktop" ];
    };
    dbus.system.talk = [ "org.freedesktop.systemd1" ];
  };
in
{
  confine.apps = {
    vscode = workspace // {
      package = pkgs.vscode;
      appId = "com.visualstudio.code";
      waylandAppId = "code";
      binaries = [ "code" ];
      networkPorts.fromHost = [
        13469
        34872
        58761
      ];
    };

    claude-code = workspace // {
      package = pkgs.claude-code;
      appId = "com.anthropic.ClaudeCode";
      binaries = [ "claude" ];
    };
  };
}
