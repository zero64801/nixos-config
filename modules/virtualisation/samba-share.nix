{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkEnableOption mkForce mkIf mkOption;
  inherit (lib.types) int str;

  cfg = config.nyx.virtualisation.sambaShare;
in
{
  options.nyx.virtualisation.sambaShare = {
    enable = mkEnableOption "on-demand Samba shares reachable only from the isolated libvirt bridge";

    user = mkOption {
      type = str;
      default = "smb";
      description = "Dedicated SMB-only account clients authenticate as (server-wide Samba login, not a host user). Set its password with `smbpasswd -a <user>`.";
    };

    owner = mkOption {
      type = str;
      default = "dx";
      description = "Local account that owns files written through the shares (force user).";
    };

    ownerGroup = mkOption {
      type = str;
      default = "users";
      description = "Group for files written through the shares (force group).";
    };

    dropPath = mkOption {
      type = str;
      default = "/mnt/storage/share/drop";
      description = ''
        Host -> guest one-way folder. You can write to it normally as
        yourself; clients can only read — smbd refuses write ops on it
        server-side, permanently, regardless of what a client tries.
      '';
    };

    dropShareName = mkOption {
      type = str;
      default = "drop";
      description = "SMB share name for the read-only folder.";
    };

    exchangePath = mkOption {
      type = str;
      default = "/mnt/storage/share/exchange";
      description = "Two-way folder. Clients can read and write.";
    };

    exchangeShareName = mkOption {
      type = str;
      default = "exchange";
      description = "SMB share name for the read-write folder.";
    };

    idleTimeoutMin = mkOption {
      type = int;
      default = 10;
      description = "Stop the shares automatically after this many minutes with zero active SMB connections.";
    };
  };

  config = mkIf cfg.enable {
    nyx.virtualisation.base.networkIsolation.allowedHostTCPPorts = [ 445 ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      description = "Samba share access";
    };
    users.groups.${cfg.user} = { };

    systemd.tmpfiles.rules = [
      "d ${dirOf cfg.dropPath} 0775 ${cfg.owner} ${cfg.ownerGroup} - -"
      "d ${cfg.dropPath} 0775 ${cfg.owner} ${cfg.ownerGroup} - -"
      "d ${dirOf cfg.exchangePath} 0775 ${cfg.owner} ${cfg.ownerGroup} - -"
      "d ${cfg.exchangePath} 0775 ${cfg.owner} ${cfg.ownerGroup} - -"
    ];

    services.samba = {
      enable = true;
      nmbd.enable = false;
      openFirewall = false;
      settings = {
        global = {
          "workgroup" = "WORKGROUP";
          "server string" = config.networking.hostName;
          "security" = "user";
          "server min protocol" = "SMB3";
          "server smb encrypt" = "desired";
        };
        ${cfg.dropShareName} = {
          path = cfg.dropPath;
          browseable = "yes";
          "read only" = "yes";
          "valid users" = cfg.user;
          "force user" = cfg.owner;
          "force group" = cfg.ownerGroup;
        };
        ${cfg.exchangeShareName} = {
          path = cfg.exchangePath;
          browseable = "yes";
          "read only" = "no";
          "valid users" = cfg.user;
          "force user" = cfg.owner;
          "force group" = cfg.ownerGroup;
          "create mask" = "0664";
          "directory mask" = "0775";
        };
      };
    };

    systemd.targets.samba = {
      wantedBy = mkForce [ ];
      wants = [ "samba-idle-stop.timer" ];
    };

    systemd.services.samba-idle-stop = {
      description = "Stop samba.target once it has no active SMB connections";
      path = [ config.services.samba.package ];
      serviceConfig.Type = "oneshot";
      script = ''
        # grep -c exits 1 at zero matches; set -e would kill the unit in
        # exactly the idle case this service exists for
        conns=$(smbstatus -p 2>/dev/null | grep -cE '^[0-9]+[[:space:]]' || true)
        if [ "$conns" -eq 0 ]; then
          echo "samba: idle, stopping samba.target"
          systemctl stop samba.target
        fi
      '';
    };

    systemd.timers.samba-idle-stop = {
      description = "Periodic idle check for the on-demand samba shares";
      timerConfig = {
        OnActiveSec = "${toString cfg.idleTimeoutMin}min";
        OnUnitActiveSec = "${toString cfg.idleTimeoutMin}min";
        Unit = "samba-idle-stop.service";
      };
      partOf = [ "samba.target" ];
    };
  };
}
