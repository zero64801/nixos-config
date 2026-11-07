{
  config,
  inputs,
  lib,
  pkgs,
  options,
  utils,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optional optionals optionalString;
  inherit (lib.types) bool nullOr path str;

  cfg      = config.my.impermanence;
  hostname = config.networking.hostName;

  persistenceConfigPath =
    if cfg.configRepoPath != null then
      "${cfg.configRepoPath}/hosts/${hostname}/persist.json"
    else
      null;

  emptyPersistence = { directories = [ ]; files = [ ]; users = { }; };

  persistenceConfig =
    if cfg.persistenceConfigFile != null && builtins.pathExists cfg.persistenceConfigFile then
      let raw = builtins.readFile cfg.persistenceConfigFile; in
      if raw == "" then emptyPersistence else builtins.fromJSON raw
    else
      emptyPersistence;

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
  allFiles       = (persistenceConfig.files or [ ])       ++ presetFiles;
  allUsers       = persistenceConfig.users or { };

  # masterPersistence is built from direct source inputs because reading back config.environment.persistence during the module fixed point breaks rollback and bind mounts.

  resolvePath = homeDir: p:
    if lib.hasPrefix "/" p then p else "${homeDir}/${p}";

  resolveEntry = homeDir: entry:
    if builtins.isString entry then
      resolvePath homeDir entry
    else if builtins.isAttrs entry && entry ? directory then
      entry // { directory = resolvePath homeDir entry.directory; }
    else if builtins.isAttrs entry && entry ? file then
      entry // { file = resolvePath homeDir entry.file; }
    else
      entry;

  localPersistence =
    [ { type = "directories"; paths = allDirectories; }
      { type = "files";       paths = allFiles; }
    ]
    ++ lib.concatMap (u:
      let
        uCfg    = allUsers.${u};
        homeDir = config.users.users.${u}.home or "/home/${u}";
      in
      [ { type = "directories"; paths = map (resolveEntry homeDir) (uCfg.directories or []); }
        { type = "files";       paths = map (resolveEntry homeDir) (uCfg.files or []); }
      ]
    ) (builtins.attrNames allUsers);

  myPersistence =
    if config.my ? persistence then
      let
        myCfg  = config.my.persistence;
        user    = config.my.flake.user;
        homeDir = config.users.users.${user}.home or "/home/${user}";
      in
      [ { type = "directories"; paths = myCfg.directories; }
        { type = "files";       paths = myCfg.files; }
        { type = "directories"; paths = map (resolveEntry homeDir) myCfg.home.directories; }
        { type = "files";       paths = map (resolveEntry homeDir) myCfg.home.files; }
      ]
    else [];

  hmPersistence =
    if (config ? home-manager) then
      lib.concatMap (user:
        let hmConfig = config.home-manager.users.${user}; in
        lib.concatMap (mountPoint:
          let pCfg = hmConfig.home.persistence.${mountPoint}; in
          lib.optionals pCfg.enable [
            { type = "directories"; paths = map (d: d.dirPath)  pCfg.directories; }
            { type = "files";       paths = map (f: f.filePath) pCfg.files; }
          ]
        ) (builtins.attrNames (hmConfig.home.persistence or {}))
      ) (builtins.attrNames config.home-manager.users)
    else [];

  extractPath = x:
    if builtins.isString x then x
    else if builtins.isAttrs x then (x.directory or x.file or null)
    else null;

  aggregate = type: lists:
    lib.unique
      (lib.filter (p: p != null)
        (map extractPath
          (lib.flatten
            (map (x: x.paths) (lib.filter (x: x.type == type) lists)))));

  allPersistencePaths = localPersistence ++ myPersistence ++ hmPersistence;

  masterPersistence = {
    directories = aggregate "directories" allPersistencePaths;
    files       = aggregate "files"       allPersistencePaths;
  };

  masterPersistenceJson = pkgs.writeText "master-persistence.json"
    (builtins.toJSON masterPersistence);

  persist = pkgs.callPackage ./_cli.nix {
    inherit (cfg) persistentStoragePath configRepoPath;
    inherit hostname persistenceConfigPath;
    inherit masterPersistenceJson;
  };

  rollbackScript =
    let
      device           = cfg.btrfs.device;
      rootSubvolume    = cfg.btrfs.rootSubvolume;
      blankSnapshot    = cfg.btrfs.blankSnapshot;
      previousSnapshot = cfg.btrfs.previousSnapshot;
    in
    ''
      # The systemd initrd ships no sed, grep or awk, and pipefail makes a missing tool abort instead of feeding the loop an empty list.
      set -o pipefail

      echo "impermanence: mounting btrfs volume"
      mkdir -p /mnt
      mount ${device} /mnt

      echo "impermanence: cleaning up nested subvolumes under ${rootSubvolume}"
      # The full list rather than -o catches grandchildren, the prefix strip keeps paths with spaces and the reverse sort deletes children before their parents.
      btrfs subvolume list /mnt \
        | while IFS= read -r line; do printf '%s\n' "''${line#* path }"; done \
        | sort -r \
        | while IFS= read -r subvolume; do
        case "$subvolume" in
          "${lib.removePrefix "/" rootSubvolume}"/*) ;;
          *) continue ;;
        esac
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
  imports = [
    inputs.impermanence.nixosModules.impermanence
  ];

  options.my.impermanence = {
    enable = mkEnableOption "impermanence under my.*";

    persistentStoragePath = mkOption {
      type    = str;
      default = "/persist/local";
      description = "Base path for persistent storage.";
    };

    configRepoPath = mkOption {
      type    = nullOr str;
      default = config.my.flakePath;
      example = "/home/dx/nixos";
      description = "Path to the NixOS configuration repository. Defaults to my.flakePath.";
    };

    persistenceConfigFile = mkOption {
      type    = nullOr path;
      default = null;
      description = "Path to the persistence.json file for this host.";
    };

    hideMounts = mkOption {
      type    = bool;
      default = true;
      description = "Hide bind mounts from file managers.";
    };

    presets = {
      system    = mkEnableOption "common system directories and files";
      network   = mkEnableOption "network-related persistence";
      bluetooth = mkEnableOption "Bluetooth persistence";
      ssh       = mkEnableOption "SSH host keys persistence";
    };

    btrfs = {
      enable           = mkEnableOption "btrfs rollback on boot";
      device           = mkOption { type = str;        default = "/dev/disk/by-label/nixos"; };
      rootSubvolume    = mkOption { type = str;        default = "/root"; };
      blankSnapshot    = mkOption { type = str;        default = "/snapshots/root/blank"; };
      previousSnapshot = mkOption { type = str;        default = "/snapshots/root/previous"; };
      keepPrevious     = mkOption { type = bool;       default = true; };
      unlockDevice     = mkOption { type = nullOr str; default = null; };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = options ? environment.persistence;
          message   = "my.impermanence requires the impermanence module.";
        }
      ];

      environment.persistence.${cfg.persistentStoragePath} = {
        inherit (cfg) hideMounts;
        directories = allDirectories;
        files       = allFiles;
        users       = allUsers;
      };

      environment.systemPackages = [
        persist
        (pkgs.writeTextDir "share/fish/vendor_completions.d/persist.fish" (builtins.readFile ./_completions.fish))
      ];

      warnings = optional (cfg.persistenceConfigFile == null)
        "my.impermanence: persistenceConfigFile is unset; persist.json cannot be read under pure evaluation, so only presets apply. Set persistenceConfigFile = ./persist.json;";

      systemd.tmpfiles.rules =
        lib.optionals (persistenceConfigPath != null) [
          ''f ${persistenceConfigPath} 0644 ${config.my.flake.user} users - {"directories":[],"files":[],"users":{}}''
        ];
    }

    (mkIf cfg.btrfs.enable {
      boot.initrd.systemd.services.impermanence-rollback =
        let
          # Wait for the backing device itself, not just the unlocker, or the mount can race udev when unlockDevice is unset.
          deviceUnit = "${utils.escapeSystemdPath cfg.btrfs.device}.device";
        in
        {
          description = "Rollback btrfs root to blank snapshot";
          wantedBy    = [ "initrd.target" ];
          before      = [ "sysroot.mount" ];
          requiredBy  = [ "sysroot.mount" ];
          after       = [ deviceUnit ] ++ optional (cfg.btrfs.unlockDevice != null) cfg.btrfs.unlockDevice;
          requires    = [ deviceUnit ] ++ optional (cfg.btrfs.unlockDevice != null) cfg.btrfs.unlockDevice;
          unitConfig = {
            DefaultDependencies = "no";
            # The switch-root isolate re-propagates sysroot.mount's Requires as a fresh start job, and a second run would wipe the mounted root live.
            ConditionPathIsMountPoint = "!/sysroot";
          };
          serviceConfig = {
            Type = "oneshot";
            # Stay active after success so that re-propagated start job is a no-op instead of re-executing the script.
            RemainAfterExit = true;
          };
          script = rollbackScript;
        };
    })
  ]);
}
