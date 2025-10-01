{
  disko.devices = {
    disk = {
      nvme0n1 = {
        type = "disk";
        device = "/dev/nvme0n1";
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
                mountOptions = [
                  "defaults"
                ];
              };
            };
            luks = {
              size = "100%";
              label = "luks";
              content = {
                type = "luks";
                name = "cryptroot";
                extraFormatArgs = [ "--type luks2" ];
                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [ "fido2-device=auto" ];
                };
                content = {
                  type = "btrfs";
                  extraArgs = [ "-L nixos" ];
                  preUnmountHook = ''
		    MNTPOINT=/mnt        

                    mkdir -p $MNTPOINT/root/boot
                    mkdir -p $MNTPOINT/root/nix
                    mkdir -p $MNTPOINT/root/snapshots
                    mkdir -p $MNTPOINT/root/persist
                    mkdir -p $MNTPOINT/root/persist/local
                    mkdir -p $MNTPOINT/root/persist/safe

                    mkdir -p /mnt/snapshots/root
                    btrfs subvolume snapshot -r $MNTPOINT/root $MNTPOINT/snapshots/root/blank
                  '';
                  subvolumes = {
                    "/root" = {
                      mountpoint = "/";
                      mountOptions = [ "subvol=root" "noatime" "nodiratime" "ssd" ];
                    };
                    "/nix" = {
                      mountpoint = "/nix";
                      mountOptions = [ "subvol=nix" "noatime" "nodiratime" "ssd" "compress=zstd" ];
                    };
                    "/snapshots" = {
                      mountpoint = "/snapshots";
                      mountOptions = [ "subvol=snapshots" "noatime" "nodiratime" "ssd" ];
                    };
                    "/persist_local" = {
                      mountpoint = "/persist/local";
                      mountOptions = [ "subvol=persist_local" "noatime" "nodiratime" "ssd" ];
                    };
                    "/persist_safe" = {
                      mountpoint = "/persist/safe";
                      mountOptions = [ "subvol=persist_safe" "noatime" "nodiratime" "ssd" ];
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

  fileSystems = {
    "/persist/local".neededForBoot = true;
    "/persist/safe".neededForBoot = true;
  };  
}
