{ config, inputs, lib, pkgs, ... }:

let
  user = config.nyx.flake.user;
  storageDev = "/dev/disk/by-path/pci-0000:6e:00.0-nvme-1";
  storageMount = "/mnt/storage";

  sopsEnabled = config.nyx.sops.enable or false;
  luksKeyFile =
    if sopsEnabled
    then config.sops.secrets.luks.path
    else null;
in
{
  imports = [ inputs.disko.nixosModules.disko ];

  disko.devices.disk = {
    main = {
      type = "disk";
      device = "/dev/disk/by-path/pci-0000:04:00.0-nvme-1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            label = "boot";
            name = "ESP";
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "defaults" ];
            };
          };
          luks = {
            size = "100%";
            label = "luks";
            content = {
              type = "luks";
              name = "cryptroot";
              extraFormatArgs = [ "--type luks2" ];
              askPassword = !sopsEnabled;
              passwordFile = lib.mkIf sopsEnabled luksKeyFile;
              settings = {
                allowDiscards = true;
                crypttabExtraOpts = [ "fido2-device=auto" ];
              };
              content = {
                type = "btrfs";
                extraArgs = [ "-L nixos" ];
                postCreateHook = ''
                  TMP_MNT=$(mktemp -d)
                  mount "$device" "$TMP_MNT"

                  mkdir -p "$TMP_MNT/root/boot"
                  mkdir -p "$TMP_MNT/root/nix"
                  mkdir -p "$TMP_MNT/root/snapshots"
                  mkdir -p "$TMP_MNT/root/persist"
                  mkdir -p "$TMP_MNT/root/persist/local"
                  mkdir -p "$TMP_MNT/root/persist/safe"

                  mkdir -p "$TMP_MNT/snapshots/root"

                  btrfs subvolume snapshot -r "$TMP_MNT/root" "$TMP_MNT/snapshots/root/blank"

                  umount "$TMP_MNT"
                  rmdir "$TMP_MNT"
                '';
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = [ "noatime" "nodiratime" "ssd" ];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "noatime" "nodiratime" "ssd" "compress=zstd" ];
                  };
                  "/snapshots" = {
                    mountpoint = "/snapshots";
                    mountOptions = [ "noatime" "nodiratime" "ssd" ];
                  };
                  "/persist_local" = {
                    mountpoint = "/persist/local";
                    mountOptions = [ "noatime" "nodiratime" "ssd" ];
                  };
                  "/persist_safe" = {
                    mountpoint = "/persist/safe";
                    mountOptions = [ "noatime" "nodiratime" "ssd" ];
                  };
                };
              };
            };
          };
        };
      };
    };

    storage = {
      type = "disk";
      device = storageDev;
      destroy = false;
      content = {
        type = "gpt";
        partitions = {
          luks = {
            size = "100%";
            label = "storage_luks";
            content = {
              type = "luks";
              name = "cryptstorage";
              extraFormatArgs = [ "--type luks2" ];
              passwordFile = lib.mkIf sopsEnabled luksKeyFile;
              settings = {
                allowDiscards = true;
                crypttabExtraOpts = [
                  "fido2-device=auto"
                  "nofail"
                  "x-systemd.device-timeout=10s"
                ];
              };
              content = {
                type = "btrfs";
                extraArgs = [ "-L storage" ];
                mountpoint = storageMount;
                mountOptions = [
                  "noatime"
                  "nodiratime"
                  "compress=zstd"
                  "ssd"
                  "nofail"
                  "x-systemd.device-timeout=10s"
                ];
              };
            };
          };
        };
      };
    };
  };

  fileSystems = {
    "/persist/local".neededForBoot = true;
    "/persist/safe".neededForBoot = true;
  };

  systemd.tmpfiles.rules = [
    "d ${storageMount} 0755 ${user} users -"
  ];

  system.activationScripts.initStorage = {
    deps = [ "specialfs" ] ++ lib.optional sopsEnabled "setupSecrets";
    text = ''
      DEV=${storageDev}
      PART="$DEV-part1"
      MAPPER=cryptstorage-init

      [ -b "$DEV" ] || exit 0

      ${lib.optionalString sopsEnabled ''
      if [ ! -s "${luksKeyFile}" ]; then
        echo ">>> init-storage: sops key file ${luksKeyFile} missing — sops setup failed." >&2
        echo ">>> init-storage: aborting to avoid leaving the drive half-formatted." >&2
        exit 0
      fi
      ''}

      cleanup() {
        if [ -b "/dev/mapper/$MAPPER" ]; then
          ${pkgs.cryptsetup}/bin/cryptsetup close "$MAPPER" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT

      if [ ! -b "$PART" ]; then
        if ls "$DEV"-part* >/dev/null 2>&1; then
          echo ">>> init-storage: $DEV has unexpected partitions, refusing to auto-format." >&2
          echo ">>> init-storage: wipe manually with \`wipefs -a $DEV\` to opt in." >&2
          exit 0
        fi

        echo ">>> init-storage: blank drive on $DEV — creating GPT + LUKS"
        ${pkgs.util-linux}/bin/sfdisk --wipe always "$DEV" <<EOF
      label: gpt
      start=1MiB, size=, name=storage_luks
      EOF
        ${pkgs.parted}/bin/partprobe "$DEV"
        ${pkgs.coreutils}/bin/sleep 1

        ${if sopsEnabled then ''
        ${pkgs.cryptsetup}/bin/cryptsetup luksFormat --type luks2 --batch-mode \
          --key-file=${luksKeyFile} "$PART"
        '' else ''
        echo ">>> init-storage: enter a new LUKS passphrase (verified)"
        ${pkgs.cryptsetup}/bin/cryptsetup luksFormat --type luks2 --batch-mode --verify-passphrase "$PART"
        ''}
      fi

      if ${pkgs.cryptsetup}/bin/cryptsetup isLuks "$PART" 2>/dev/null; then
        if [ ! -b "/dev/mapper/$MAPPER" ]; then
          ${pkgs.cryptsetup}/bin/cryptsetup open ${lib.optionalString sopsEnabled "--key-file=${luksKeyFile} "}"$PART" "$MAPPER"
        fi

        INNER_TYPE=$(${pkgs.util-linux}/bin/blkid -o value -s TYPE "/dev/mapper/$MAPPER" 2>/dev/null || echo "")
        if [ -z "$INNER_TYPE" ]; then
          echo ">>> init-storage: creating btrfs"
          ${pkgs.btrfs-progs}/bin/mkfs.btrfs -L storage "/dev/mapper/$MAPPER"
        elif [ "$INNER_TYPE" != "btrfs" ]; then
          echo ">>> init-storage: inner filesystem is $INNER_TYPE, not btrfs — refusing to touch." >&2
        fi

        ${pkgs.cryptsetup}/bin/cryptsetup close "$MAPPER" 2>/dev/null || true
      fi

      if ${pkgs.cryptsetup}/bin/cryptsetup isLuks "$PART" 2>/dev/null; then
        if ${pkgs.cryptsetup}/bin/cryptsetup luksDump "$PART" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "systemd-fido2"; then
          :
        else
          FIDO_LIST=$(${pkgs.systemd}/bin/systemd-cryptenroll --fido2-device=list 2>/dev/null || true)
          if echo "$FIDO_LIST" | ${pkgs.gnugrep}/bin/grep -q "/dev/hidraw"; then
            echo ">>> init-storage: enrolling FIDO2 key (touch it when it flashes)"
            ${pkgs.systemd}/bin/systemd-cryptenroll ${lib.optionalString sopsEnabled "--unlock-key-file=${luksKeyFile} "}--fido2-device=auto "$PART" || \
              echo ">>> init-storage: FIDO2 enrollment failed — passphrase still works, retry later."
          else
            echo ">>> init-storage: no FIDO2 device detected — plug in YubiKey and rerun rebuild to enroll."
          fi
        fi
      fi
    '';
  };
}
