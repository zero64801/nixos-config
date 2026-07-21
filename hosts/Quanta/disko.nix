{ config, inputs, pkgs, ... }:

let
  user = config.nyx.flake.user;
  storageDev = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_4000GB_25226M800213";
  storageMount = "/mnt/storage";

  vaultDev = "/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_8TB_S7YHNJ0L101775M";
  vaultMount = "/mnt/vault";

  mkDiskInit = { name, device, mount, cryptName, label, partLabel }:
    pkgs.writeShellApplication {
      name = "${name}-init";
      runtimeInputs = with pkgs; [ gptfdisk cryptsetup util-linux systemd btrfs-progs coreutils ];
      text = ''
        DEV=${device}
        PART=${device}-part1

        if [ "$(id -u)" -ne 0 ]; then echo "${name}-init: run as root" >&2; exit 1; fi

        if blkid "$DEV" >/dev/null 2>&1 || [ "$(lsblk -rno NAME "$DEV" | wc -l)" -gt 1 ]; then
          echo "$DEV is not blank:" >&2
          lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV" >&2 || true
          printf 'Type ERASE to wipe and reinitialise, anything else to abort: ' >&2
          read -r ans || ans=""
          [ "$ans" = "ERASE" ] || { echo "aborted" >&2; exit 1; }
          umount "${mount}" 2>/dev/null || true
          cryptsetup close ${cryptName} 2>/dev/null || true
          wipefs -a "$DEV"
        fi

        sgdisk --zap-all "$DEV"
        sgdisk -n 1:0:0 -t 1:8309 -c 1:${partLabel} "$DEV"
        udevadm settle
        [ -e "$PART" ] || { echo "${name}-init: $PART did not appear" >&2; exit 1; }

        KEY=$(mktemp)
        trap 'rm -f "$KEY"' EXIT
        head -c 512 /dev/urandom > "$KEY"

        cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEY" "$PART"
        cryptsetup open --key-file "$KEY" "$PART" ${cryptName}
        mkfs.btrfs -L ${label} /dev/mapper/${cryptName}

        echo "Enrolling FIDO2 — touch the key when it blinks."
        systemd-cryptenroll --unlock-key-file="$KEY" --fido2-device=auto "$PART"
        cryptsetup luksRemoveKey "$PART" "$KEY"

        printf 'Mount ${name} at ${mount} now? [Y/n] '
        read -r m || m=""
        case "$m" in
          ""|y|Y)
            mkdir -p "${mount}"
            mount /dev/mapper/${cryptName} "${mount}"
            chown ${user}:users "${mount}"
            chmod 0755 "${mount}"
            echo "mounted at ${mount}, owned by ${user}" ;;
          *)
            cryptsetup close ${cryptName} ;;
        esac

        echo "${name} ready (FIDO2-only). Run 'nixos-rebuild switch' for boot auto-mount."
        echo "No passphrase fallback: losing the FIDO2 key means the data is unrecoverable."
      '';
    };

  vaultInit = mkDiskInit {
    name = "vault"; device = vaultDev; mount = vaultMount;
    cryptName = "cryptvault"; label = "vault"; partLabel = "vault_luks";
  };
  storageInit = mkDiskInit {
    name = "storage"; device = storageDev; mount = storageMount;
    cryptName = "cryptstorage"; label = "storage"; partLabel = "storage_luks";
  };
in
{
  imports = [ inputs.disko.nixosModules.disko ];

  disko.devices.disk = {
    main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-Corsair_MP700_PRO_A7GFB514003ALK";
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
              mountOptions = [ "umask=0077" ];
            };
          };
          luks = {
            size = "100%";
            label = "luks";
            content = {
              type = "luks";
              name = "cryptroot";
              extraFormatArgs = [ "--type luks2" ];
              askPassword = true;
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

                  mkdir -p "$TMP_MNT/snapshots/root"

                  btrfs subvolume snapshot -r "$TMP_MNT/root" "$TMP_MNT/snapshots/root/blank"

                  umount "$TMP_MNT"
                  rmdir "$TMP_MNT"
                '';
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = [ "noatime" "ssd" "compress=zstd" ];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "noatime" "ssd" "compress=zstd" ];
                  };
                  "/snapshots" = {
                    mountpoint = "/snapshots";
                    mountOptions = [ "noatime" "ssd" ];
                  };
                  "/persist_local" = {
                    mountpoint = "/persist/local";
                    mountOptions = [ "noatime" "ssd" "compress=zstd" ];
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
              settings = {
                allowDiscards = true;
                crypttabExtraOpts = [
                  "fido2-device=auto"
                ];
              };
              content = {
                type = "btrfs";
                extraArgs = [ "-L storage" ];
                mountpoint = storageMount;
                mountOptions = [
                  "noatime"
                  "compress=zstd"
                  "ssd"
                  "nofail"
                ];
              };
            };
          };
        };
      };
    };

    vault = {
      type = "disk";
      device = vaultDev;
      destroy = false;
      content = {
        type = "gpt";
        partitions = {
          luks = {
            size = "100%";
            label = "vault_luks";
            content = {
              type = "luks";
              name = "cryptvault";
              extraFormatArgs = [ "--type luks2" ];
              settings = {
                allowDiscards = true;
                crypttabExtraOpts = [ "fido2-device=auto" ];
              };
              content = {
                type = "btrfs";
                extraArgs = [ "-L vault" ];
                mountpoint = vaultMount;
                mountOptions = [ "noatime" "compress=zstd" "ssd" "nofail" ];
              };
            };
          };
        };
      };
    };
  };

  environment.systemPackages = [ vaultInit storageInit ];

  fileSystems = {
    "/persist/local".neededForBoot = true;
  };

  systemd.tmpfiles.rules = [
    "d ${storageMount} 0755 ${user} users -"
    "d ${vaultMount} 0755 ${user} users -"
    "d ${vaultMount}/secrets 0700 ${user} users -"
  ];
}
