{
  config,
  lib,
  pkgs,
  options,
  ...
}:

with lib;

let
  cfg = config.nyx.impermanence;
  hostname = config.networking.hostName;

  persistenceConfigPath =
    if cfg.configRepoPath != null then
      "${cfg.configRepoPath}/hosts/${hostname}/persistence.nix"
    else
      null;

  persistenceConfig =
    if cfg.persistenceConfigFile != null then
      import cfg.persistenceConfigFile
    else
      {
        directories = [ ];
        files = [ ];
        users = { };
      };

  persistenceData = lib.mapAttrs (name: pCfg: {
    directories = map (d: d.dirPath) pCfg.directories;
    files = map (f: f.filePath) pCfg.files;
    users = lib.mapAttrs (user: uCfg: {
      directories = map (d: d.dirPath) uCfg.directories;
      files = map (f: f.filePath) uCfg.files;
    }) pCfg.users;
  }) config.environment.persistence;

  persistenceJson = pkgs.writeText "persistence.json" (builtins.toJSON persistenceData);

  nyx-persist = pkgs.callPackage ./cli.nix {
    inherit (cfg) persistentStoragePath configRepoPath;
    inherit hostname persistenceConfigPath;
    inherit persistenceJson;
  };

  presetDirectories =
    optionals cfg.presets.system [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ]
    ++ optionals cfg.presets.network [
      "/var/lib/NetworkManager"
      "/etc/NetworkManager/system-connections"
    ]
    ++ optionals cfg.presets.bluetooth [
      "/var/lib/bluetooth"
    ];

  presetFiles =
    optionals cfg.presets.system [
      "/etc/machine-id"
      "/etc/adjtime"
    ]
    ++ optionals cfg.presets.ssh [
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];

  allDirectories = (persistenceConfig.directories or [ ]) ++ presetDirectories;
  allFiles = (persistenceConfig.files or [ ]) ++ presetFiles;
  allUsers = persistenceConfig.users or { };

  rollbackScript =
    let
      device = cfg.btrfs.device;
      rootSubvolume = cfg.btrfs.rootSubvolume;
      blankSnapshot = cfg.btrfs.blankSnapshot;
      previousSnapshot = cfg.btrfs.previousSnapshot;
    in
    ''
      echo "impermanence: mounting btrfs volume"
      mkdir -p /mnt
      mount ${device} /mnt

      echo "impermanence: cleaning up nested subvolumes under ${rootSubvolume}"
      btrfs subvolume list -o /mnt${rootSubvolume} | cut -f9 -d' ' | while read subvolume; do
        echo "impermanence: deleting /$subvolume"
        btrfs subvolume delete "/mnt/$subvolume"
      done

      ${optionalString cfg.btrfs.keepPrevious ''
        if [ -d "/mnt${previousSnapshot}" ]; then
          echo "impermanence: deleting previous backup"
          btrfs subvolume delete /mnt${previousSnapshot}
        fi

        echo "impermanence: creating backup of current root"
        btrfs subvolume snapshot -r /mnt${rootSubvolume} /mnt${previousSnapshot}
      ''}

      echo "impermanence: deleting ${rootSubvolume}"
      btrfs subvolume delete /mnt${rootSubvolume}

      echo "impermanence: restoring from ${blankSnapshot}"
      btrfs subvolume snapshot /mnt${blankSnapshot} /mnt${rootSubvolume}

      echo "impermanence: unmounting"
      umount /mnt

      echo "impermanence: rollback complete"
    '';

in
{
  options.nyx.impermanence = {
    enable = mkEnableOption "impermanence with nyx management";

    persistentStoragePath = mkOption {
      type = types.str;
      default = "/persist/local";
      description = "Base path for persistent storage.";
    };

    configRepoPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/home/dx/nixos";
      description = "Path to the NixOS configuration repository.";
    };

    persistenceConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to the persistence.nix file for this host.";
    };

    hideMounts = mkOption {
      type = types.bool;
      default = true;
      description = "Hide bind mounts from file managers.";
    };

    presets = {
      system = mkEnableOption "common system directories";
      network = mkEnableOption "network-related persistence";
      bluetooth = mkEnableOption "Bluetooth persistence";
      ssh = mkEnableOption "SSH host keys persistence";
    };

    btrfs = {
      enable = mkEnableOption "btrfs rollback on boot";
      device = mkOption { type = types.str; default = "/dev/disk/by-label/nixos"; };
      rootSubvolume = mkOption { type = types.str; default = "/root"; };
      blankSnapshot = mkOption { type = types.str; default = "/snapshots/root/blank"; };
      previousSnapshot = mkOption { type = types.str; default = "/snapshots/root/previous"; };
      keepPrevious = mkOption { type = types.bool; default = true; };
      unlockDevice = mkOption { type = types.nullOr types.str; default = null; };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = options ? environment.persistence;
          message = "nyx.impermanence requires the impermanence module.";
        }
        {
          assertion = cfg.btrfs.enable -> config.boot.initrd.systemd.enable;
          message = "nyx.impermanence.btrfs requires boot.initrd.systemd.enable = true";
        }
      ];

      environment.persistence.${cfg.persistentStoragePath} = {
        inherit (cfg) hideMounts;
        directories = allDirectories;
        files = allFiles;
        users = allUsers;
      };

      environment.systemPackages = [ nyx-persist ];
    }

    (mkIf cfg.btrfs.enable {
      boot.initrd.systemd.services.impermanence-rollback = {
        description = "Rollback btrfs root to blank snapshot";
        wantedBy = [ "initrd.target" ];
        before = [ "sysroot.mount" ];
        after = optional (cfg.btrfs.unlockDevice != null) cfg.btrfs.unlockDevice;
        requires = optional (cfg.btrfs.unlockDevice != null) cfg.btrfs.unlockDevice;
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = rollbackScript;
      };
    })
  ]);
}
