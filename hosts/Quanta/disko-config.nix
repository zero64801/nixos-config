{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            # EFI System Partition (ESP)
            boot = {
              size = "1G";
              type = "EF00";
              label = "ESP";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "fmask=0022"
                  "dmask=0022"
                ];
              };
            };

            # LUKS-encrypted root partition
            luks = {
              size = "100%";
              label = "cryptroot";
              content = {
                type = "luks";
                name = "cryptroot";
                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [ "fido2-device=auto" ];
                };
                content = {
                  # The content of the LUKS container is the BTRFS filesystem
                  type = "btrfs";
                  extraArgs = [ "-L nixos" ]; # Label the filesystem
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
    };
  };
}
