{ config, lib, pkgs, ... }:

let
  flake = config.my.flakePath;
  sandboxed = "${pkgs.gnugrep}/bin/grep -q '^NoNewPrivs:[[:space:]]*1' /proc/self/status";

  rebuildNh = pkgs.writeShellScriptBin "nh" ''
    if ${sandboxed}; then
      exec ${config.programs.nh.package}/bin/nh "$@"
    fi
    exec ${config.confine.packages.rebuild-eval}/bin/nh "$@"
  '';

  pin = pkgs.writeShellScriptBin "pin" ''
    if ${sandboxed}; then
      exec ${config.my.pinning.package}/bin/pin "$@"
    fi
    exec ${config.confine.packages.pin}/bin/pin "$@"
  '';
in
lib.mkMerge [
  (lib.mkIf config.my.cli.enable {
    confine.apps.rebuild-eval = {
      package = config.programs.nh.package;
      appId = "org.nixos.Rebuild";
      install = false;
      persist = false;
      network = "isolated";
      binds.ro = [
        flake
        "/nix/var/nix/daemon-socket"
      ];
      binds.rw = [ "xdg-run/rebuild" ];
      env = {
        NIX_REMOTE = "daemon";
        NH_FLAKE = flake;
        NH_OS_FLAKE = flake;
      };
      envPassthrough = [ "NIX_PATH" ];
    };

    my.cli.rebuildNh = rebuildNh;
  })

  (lib.mkIf config.my.pinning.enable {
    confine.apps.pin = {
      package = config.my.pinning.package;
      appId = "org.nixos.Pin";
      install = false;
      persist = false;
      network = "isolated";
      binds.rw = [ config.my.pinning.flakePath ];
      binds.ro = [ "/nix/var/nix/daemon-socket" ];
      gitGuard.enable = true;
      env.NIX_REMOTE = "daemon";
      envPassthrough = [
        "MY_FLAKE_PATH"
        "MY_HOST"
        "MY_PINS_FILE"
      ];
    };

    environment.systemPackages = [ (lib.hiPrio pin) ];
  })
]
