{ config, lib, ... }:

let
  user = config.nyx.flake.user;
in
{
  disko.devices = {
    disk = {
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
                    mkdir -p "$TMP_MNT/root/persist/safe"

                    mkdir -p "$TMP_MNT/snapshots/root"

                    # Create the blank snapshot for impermanence rollback
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
        device = "/dev/disk/by-path/pci-0000:07:00.0-nvme-1";
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
                  crypttabExtraOpts = [ "fido2-device=auto" ];
                };
                content = {
                  type = "btrfs";
                  extraArgs = [ "-L storage" ];
                  subvolumes = {
                    "/data" = {
                      mountpoint = "/mnt/storage";
                      mountOptions = [
                        "noatime"
                        "nodiratime"
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
        };
      };
    };
  };

  # Needed for impermanence
  fileSystems = {
    "/persist/local".neededForBoot = true;
    "/persist/safe".neededForBoot = true;
  };

  # -- Permissions Rules --
  systemd.tmpfiles.rules = [
    "d /mnt/storage 0755 ${user} users -"
  ];
}
