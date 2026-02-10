{
  config,
  lib,
  pkgs,
  options,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption mapAttrs optional optionals optionalString;
  inherit (lib.types) bool nullOr path str;

  cfg = config.nyx.impermanence;
  hostname = config.networking.hostName;

  persistenceConfigPath =
    if cfg.configRepoPath != null then
      "${cfg.configRepoPath}/hosts/${hostname}/persist.json"
    else
      null;

  persistenceConfig =
    if cfg.persistenceConfigFile != null && builtins.pathExists cfg.persistenceConfigFile then
      builtins.fromJSON (builtins.readFile cfg.persistenceConfigFile)
    else if persistenceConfigPath != null && builtins.pathExists persistenceConfigPath then
      builtins.fromJSON (builtins.readFile persistenceConfigPath)
    else
      {
        directories = [ ];
        files = [ ];
        users = { };
      };

  # Recursively extracting paths from Home Manager users
  hmPersistence = if (config ? home-manager) then (
    lib.concatMap (user:
      let
        hmConfig = config.home-manager.users.${user};
        homeDirectory = hmConfig.home.homeDirectory;
      in
      lib.concatMap (mountPoint:
        let
          pCfg = hmConfig.home.persistence.${mountPoint};
          # Helper to normalize path config which can be string or attrset
          getPaths = list: type: map (item: 
            let
              path = if builtins.isString item then item else item.${type};
              absPath = if lib.hasPrefix "/" path then path else "${homeDirectory}/${path}";
            in absPath
          ) list;
        in
        [
          { type = "directories"; paths = getPaths pCfg.directories "directory"; }
          { type = "files"; paths = getPaths pCfg.files "file"; }
        ]
      ) (builtins.attrNames (hmConfig.home.persistence or {}))
    ) (builtins.attrNames config.home-manager.users)
  ) else [];

  # System persistence (already structured in environment.persistence)
  systemPersistence = lib.concatMap (mountPoint:
    let
      pCfg = config.environment.persistence.${mountPoint};
    in
    [
      { type = "directories"; paths = map (d: d.dirPath) pCfg.directories; }
      { type = "files"; paths = map (f: f.filePath) pCfg.files; }
    ] ++ lib.concatMap (user:
      let
        uCfg = pCfg.users.${user};
      in
      [
        { type = "directories"; paths = map (d: d.dirPath) uCfg.directories; }
        { type = "files"; paths = map (f: f.filePath) uCfg.files; }
      ]
    ) (builtins.attrNames pCfg.users)
  ) (builtins.attrNames config.environment.persistence);
  
  # Helper to aggregate by type
  aggregate = type: lists: 
    lib.unique (lib.flatten (map (x: x.paths) (lib.filter (x: x.type == type) lists)));

  allPersistencePaths = systemPersistence ++ (if (config ? home-manager) then hmPersistence else []);

  masterPersistence = {
    directories = aggregate "directories" allPersistencePaths;
    files = aggregate "files" allPersistencePaths;
  };

  masterPersistenceJson = pkgs.writeText "master-persistence.json" (builtins.toJSON masterPersistence);

  nyx-persist = pkgs.callPackage ./_cli.nix {
    inherit (cfg) persistentStoragePath configRepoPath;
    inherit hostname persistenceConfigPath;
    inherit masterPersistenceJson;
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
      type = str;
      default = "/persist/local";
      description = "Base path for persistent storage.";
    };

    configRepoPath = mkOption {
      type = nullOr str;
      default = null;
      example = "/home/dx/nixos";
      description = "Path to the NixOS configuration repository.";
    };

    persistenceConfigFile = mkOption {
      type = nullOr path;
      default = null;
      description = "Path to the persistence.nix file for this host.";
    };

    hideMounts = mkOption {
      type = bool;
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
      device = mkOption { type = str; default = "/dev/disk/by-label/nixos"; };
      rootSubvolume = mkOption { type = str; default = "/root"; };
      blankSnapshot = mkOption { type = str; default = "/snapshots/root/blank"; };
      previousSnapshot = mkOption { type = str; default = "/snapshots/root/previous"; };
      keepPrevious = mkOption { type = bool; default = true; };
      unlockDevice = mkOption { type = nullOr str; default = null; };
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
