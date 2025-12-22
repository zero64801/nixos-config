{
  config,
  lib,
  pkgs,
  options,
  ...
}:

with lib;
with builtins;

let
  cfg = config.nyx.impermanence;
  hostname = config.networking.hostName;

  # Path to persistence config (stored in config repo for reproducibility)
  persistenceConfigPath =
    if cfg.configRepoPath != null then
      "${cfg.configRepoPath}/hosts/${hostname}/persistence.nix"
    else
      null;

  # Read persistence config from Nix file if it exists
  persistenceConfig =
    if persistenceConfigPath != null && pathExists persistenceConfigPath
    then import persistenceConfigPath
    else { directories = []; files = []; users = {}; };

  # CLI tool for managing persistence
  nyx-persist = pkgs.callPackage ./cli.nix {
    inherit (cfg) persistentStoragePath configRepoPath;
    inherit hostname persistenceConfigPath;
  };

  # Preset directories and files
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

  # Merge everything
  allDirectories = (persistenceConfig.directories or [ ]) ++ presetDirectories;
  allFiles = (persistenceConfig.files or [ ]) ++ presetFiles;
  allUsers = persistenceConfig.users or { };

  # Btrfs rollback script
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
      description = ''
        Path to the NixOS configuration repository.
        Persistence paths are managed in hosts/<hostname>/persistence.nix
      '';
    };

    hideMounts = mkOption {
      type = types.bool;
      default = true;
      description = "Hide bind mounts from file managers.";
    };

    presets = {
      system = mkEnableOption "common system directories (/var/log, /var/lib/nixos, etc.)";
      network = mkEnableOption "network-related persistence (NetworkManager)";
      bluetooth = mkEnableOption "Bluetooth persistence";
      ssh = mkEnableOption "SSH host keys persistence";
    };

    # Btrfs rollback configuration
    btrfs = {
      enable = mkEnableOption "btrfs rollback on boot";

      device = mkOption {
        type = types.str;
        default = "/dev/disk/by-label/nixos";
        example = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_XXXXX";
        description = ''
          Device or label to mount for rollback.
          Use /dev/disk/by-id/ or /dev/disk/by-label/ for stability.
        '';
      };

      rootSubvolume = mkOption {
        type = types.str;
        default = "/root";
        description = "Path to the root subvolume (relative to btrfs mount).";
      };

      blankSnapshot = mkOption {
        type = types.str;
        default = "/snapshots/root/blank";
        description = "Path to the blank snapshot to restore from.";
      };

      previousSnapshot = mkOption {
        type = types.str;
        default = "/snapshots/root/previous";
        description = "Path to store the previous root backup.";
      };

      keepPrevious = mkOption {
        type = types.bool;
        default = true;
        description = "Keep a backup of the previous root before wiping.";
      };

      unlockDevice = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "dev-mapper-cryptroot.device";
        description = ''
          Systemd device unit to wait for before rollback.
          Set this if using LUKS encryption (e.g., "dev-mapper-cryptroot.device").
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Assertions
    {
      assertions = [
        {
          assertion = options ? environment.persistence;
          message = "nyx.impermanence requires the impermanence module to be imported.";
        }
        {
          assertion = cfg.btrfs.enable -> config.boot.initrd.systemd.enable;
          message = "nyx.impermanence.btrfs requires boot.initrd.systemd.enable = true";
        }
      ];

      warnings = optional (cfg.configRepoPath == null) ''
        nyx.impermanence: configRepoPath is not set.
        Set nyx.impermanence.configRepoPath to your NixOS config directory
        to enable the nyx-persist CLI tool and persistence.nix management.
      '';
    }

    # Base impermanence configuration
    {
      environment.persistence.${cfg.persistentStoragePath} = {
        inherit (cfg) hideMounts;
        directories = allDirectories;
        files = allFiles;
        users = allUsers;
      };

      environment.systemPackages = [ nyx-persist ];
    }

    # Btrfs rollback service
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
