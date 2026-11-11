{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.security.touchGuard;
  python = lib.getExe pkgs.python3;

  notifierArgv = [
    python
    "-I"
    "${./_notifier.py}"
    "--busctl"
    "${config.systemd.package}/bin/busctl"
  ];
in
{
  options.my.security.touchGuard = {
    enable = mkEnableOption ''
      touch-guard, which names the program and command behind every security key touch request.
      A root service detects the wait, finds who sent the request to the key and logs it to the journal, and a
      user service shows it as a notification. Kernel probes on the calls that send to a key tell the sender from
      programs that only hold it open. Where the kernel offers none, every program holding the key is named
    '';

    user = mkOption {
      type = types.str;
      default = config.my.flake.user;
      description = "The only user whose session may receive touch events.";
    };

    pamServices = mkOption {
      type = types.listOf types.str;
      default = [
        "sudo"
        "su"
        "polkit-1"
      ]
      ++ lib.optional config.security.doas.enable "doas";
      description = ''
        PAM services whose authentication waits until the request is described on screen, whatever method
        approves it. With no genuine notifier running they refuse, except on a text console.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.touch-guard = {
      description = "Security key touch requester detection";
      wantedBy = [ "multi-user.target" ];
      path = [ config.systemd.package ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          python
          "-I"
          "${./_daemon.py}"
          "--user"
          cfg.user
          "--notifier-argv"
          (pkgs.writeText "touch-guard-notifier.json" (builtins.toJSON notifierArgv))
          "--nix-store"
          "${config.nix.package}/bin/nix-store"
        ];
        Restart = "always";
        RestartSec = 2;
        RuntimeDirectory = "touch-guard";
        RuntimeDirectoryMode = "0755";

        # Root only to read every process's fd, fdinfo and exe links (ptrace read, DAC search), to monitor polkit on the system bus
        # and to set its probes under /sys/kernel/tracing, which root owns.
        CapabilityBoundingSet = [ "CAP_SYS_PTRACE" "CAP_DAC_READ_SEARCH" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        DevicePolicy = "closed";
        DeviceAllow = [ "char-hidraw r" ];
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.user.services.touch-guard-notify = {
      description = "Security key touch requester notifications";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs notifierArgv;
        Restart = "always";
        RestartSec = 1;
      };
    };

    security.pam.services = lib.genAttrs cfg.pamServices (
      svc:
      let
        # Plasma's polkit dialog dims the notification and shows one PAM message at a time, so it gets the description with the key's cue at its end.
        dialog = svc == "polkit-1";
        keyCue = dialog && config.security.pam.services.${svc}.u2f.enable && (config.security.pam.u2f.settings.cue or false);
      in
      {
        # After rootok, wheel and faillock, before the first module that can authenticate.
        rules.auth.touch-guard = {
          order = 10450;
          control = "requisite";
          modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
          args = [
            "quiet"
            "stdout"
            "seteuid"
            python
            "-I"
            "${./_pam.py}"
          ]
          ++ lib.optional dialog "--describe"
          ++ lib.optional keyCue "--key-cue";
        };
        rules.auth.u2f.settings.cue = lib.mkIf keyCue (lib.mkForce false);
      }
    );
  };
}
