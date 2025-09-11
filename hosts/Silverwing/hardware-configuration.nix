{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  boot = {
    #kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = [ "kvm-intel" "nvidia" ];
    zfs.forceImportRoot = false;
    
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "ahci"
        "nvme"
        "usb_storage"
        "sd_mod"
      ];

      systemd.enable = true;
      systemd.services.rollback = {
        description = "Back up old root and create new blank one";
        wantedBy = [
          "initrd.target"
        ];
        after = [
          "zfs-import-zpool.service"
        ];
        before = [
          "sysroot.mount"
        ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          mount -t zfs --mkdir zpool/local/root /tmp-root
          prev_boot_at=$(cat /tmp-root/booted-at)
          umount /tmp-root

          zfs set readonly=on zpool/local/root
          zfs inherit mountpoint zpool/local/root
          zfs rename zpool/local/root "zpool/local/prev-boots/$prev_boot_at"
          zfs create zpool/local/root

          mount -t zfs --mkdir zpool/local/root /tmp-root
          date '+%F %T' > /tmp-root/booted-at
          umount /tmp-root
        '';
      };
    };
  };

  fileSystems = {
    "/" = {
      device = "zpool/local/root";
      fsType = "zfs";
      neededForBoot = true;
    };

    "/boot" = {
      device = "/dev/disk/by-label/boot";
      fsType = "vfat";
      options = [ "umask=0077" ];
      neededForBoot = true;
    };

    "/nix" = {
      device = "zpool/local/nix";
      fsType = "zfs";
      neededForBoot = true;
    };

    "/persist/local" = {
      device = "zpool/local/persist";
      fsType = "zfs";
      neededForBoot = true;
    };

    "/persist/safe" = {
      device = "zpool/safe/persist";
      fsType = "zfs";
      neededForBoot = true;
    };
  };

  zramSwap.enable = true;
  networking.useDHCP = lib.mkDefault true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
