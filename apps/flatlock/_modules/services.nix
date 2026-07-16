{
  config,
  lib,
  pkgs,
  installation,
  model,
  build,
}:

let
  inherit (lib) mkIf;
  cfg = config.flatlock;
  isSystem = installation == "system";
  background = cfg.activation.mode == "background";
in
lib.mkMerge [
  {
    assertions = model.assertions;
    warnings = model.warnings;
    flatlock.remotes.flathub = lib.mkDefault "https://flathub.org/repo/flathub.flatpakrepo";
    flatlock.overridesPackage = model.overridesPackage;
  }

  (lib.optionalAttrs isSystem {
    services.flatpak.enable = true;
    environment.systemPackages = [ build.flatlock ];
    systemd.tmpfiles.rules = [
      "f /run/lock/flatlock-system.lock 0660 root users - -"
    ];

    systemd.services.flatlock = {
      description = "Reconcile declared system Flatpak state";
      wantedBy = lib.optionals (!background) [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${build.reconciler}/bin/flatlock-reconcile";
      }
      // build.restartConfig;
    };

    systemd.timers.flatlock = mkIf background {
      description = "Schedule system Flatpak reconciliation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "flatlock.service";
        OnBootSec = "0";
      };
    };

    systemd.services.flatlock-update = mkIf cfg.update.auto.enable {
      description = "Update unpinned system Flatpaks";
      wants = [ "network-online.target" ];
      requires = [ "flatlock.service" ];
      after = [
        "network-online.target"
        "flatlock.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "flatlock-update" build.updateCommand;
      };
    };

    systemd.timers.flatlock-update = mkIf cfg.update.auto.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.update.auto.onCalendar;
        Persistent = true;
      };
    };
  })

  (lib.optionalAttrs (!isSystem) {
    home.packages = [
      build.flatlock
      pkgs.flatpak
    ];
    xdg.enable = true;

    systemd.user.services.flatlock = {
      Unit.Description = "Reconcile declared user Flatpak state";
      Service = {
        Type = "oneshot";
        ExecStart = "${build.reconciler}/bin/flatlock-reconcile";
      }
      // build.restartConfig;
      Install.WantedBy = lib.optionals (!background) [ "default.target" ];
    };

    systemd.user.timers.flatlock = mkIf background {
      Unit.Description = "Schedule user Flatpak reconciliation";
      Timer = {
        Unit = "flatlock.service";
        OnStartupSec = "0";
      };
      Install.WantedBy = [ "timers.target" ];
    };

    systemd.user.services.flatlock-update = mkIf cfg.update.auto.enable {
      Unit = {
        Description = "Update unpinned user Flatpaks";
        Requires = [ "flatlock.service" ];
        After = [ "flatlock.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "flatlock-user-update" build.updateCommand;
      };
    };

    systemd.user.timers.flatlock-update = mkIf cfg.update.auto.enable {
      Unit.Description = "Schedule user Flatpak updates";
      Timer = {
        Unit = "flatlock-update.service";
        OnCalendar = cfg.update.auto.onCalendar;
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    home.activation.flatlock = config.lib.dag.entryAfter [ "reloadSystemd" ] ''
      if ${config.systemd.user.systemctlPath} --user show-environment >/dev/null 2>&1; then
        if ! run ${config.systemd.user.systemctlPath} --user start ${
          if background then "flatlock.timer" else "flatlock.service"
        }; then
          echo "flatlock: ${
            if background then "scheduling" else "reconciliation"
          } failed, inspect the user service journal" >&2
          ${if cfg.activation.failOnError then "exit 1" else "true"}
        fi
      else
        echo "flatlock: user manager unavailable, reconciliation deferred until login" >&2
      fi
    '';
  })
]
