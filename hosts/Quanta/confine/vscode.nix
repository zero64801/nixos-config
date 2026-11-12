{ config, lib, pkgs, ... }:

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
    envPassthrough = [
      "NIX_PATH"
      "SHELL"
    ];

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
      call = [
        "org.freedesktop.portal.Desktop=org.freedesktop.portal.OpenURI.*@/org/freedesktop/portal/desktop"
        "org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.*@/org/freedesktop/portal/desktop"
      ];
      broadcast = [ "org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.*@/org/freedesktop/portal/desktop" ];
    };
    dbus.system.talk = [ "org.freedesktop.systemd1" ];
  };

  git = config.my.apps.git;
  withGit = git.enable && git.github.enable;
  withInspect = config.my.virtualisation.inspect.enable;
  key = lib.removePrefix "~/" (lib.removeSuffix ".pub" git.signing.keyFile);

  gitAccess = lib.optionalAttrs withGit {
    securityKeys = true;
    env = workspace.env // {
      GIT_SSH_COMMAND = "ssh -F ${config.hm.home.file.".ssh/config".source}";
    };
  };
in
{
  confine.apps = {
    vscode = workspace // gitAccess // {
      devices = lib.optional withGit "/dev/input/by-id/*-fido" ++ lib.optional withInspect "/dev/fuse";
      binds = workspace.binds // {
        rw = workspace.binds.rw ++ [ "/home/dx/Downloads" ];
        ro =
          workspace.binds.ro
          ++ lib.optionals withGit [
            "xdg-config/git/config"
            key
            "${key}.pub"
            ".ssh/known_hosts"
          ]
          ++ lib.optionals withInspect [
            "xdg-run/vm-inspect"
            "/run/vm-inspect"
          ];
      };
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
      linger = false;
    };
  };
}
