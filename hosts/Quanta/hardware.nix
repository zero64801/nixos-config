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
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = [ "kvm-amd" ];
    kernelParams = [
      "amd_pstate=active"
    ];

    initrd = {
      availableKernelModules = [
        "nvme"
        #"xhci_pci_renesas"
        "xhci_pci"
        "ahci"
        "thunderbolt"
        "usb_storage"
        "usbhid"
        "sd_mod"
      ];

      kernelModules = [ "amdgpu" ];

      systemd.enable = true;
      systemd.services.rollback = {
        description = "Back up old root and create new blank one";
        wantedBy = [
          "initrd.target"
        ];
        after = [
          "dev-mapper-cryptroot.device"
        ];
        requires = [
          "dev-mapper-cryptroot.device"
        ];
        before = [
          "sysroot.mount"
        ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          echo "impermanence: mounting base drive"

          mkdir -p /mnt

          mount /dev/disk/by-label/nixos /mnt

          # Nobody knows how they appear there but we have to fix it
          # Source: https://mt-caret.github.io/blog/posts/2020-06-29-optin-state.html

          echo "impermanence: deleting root subvolumes"

          btrfs subvolume list -o /mnt/root | cut -f9 -d' ' |

          while read subvolume; do
            echo "impermanence: deleting /$subvolume subvolume"

            btrfs subvolume delete "/mnt/$subvolume"
          done &&

          if [ -d "/mnt/snapshots/root/previous" ]; then
            echo "impermanence: deleting previous root subvolume backup"

            btrfs subvolume delete /mnt/snapshots/root/previous
          fi &&

          echo "impermanence: making backup of the root subvolume" &&

          btrfs subvolume snapshot -r /mnt/root /mnt/snapshots/root/previous &&

          echo "impermanence: deleting root subvolume" &&

          btrfs subvolume delete /mnt/root

          echo "impermanence: restoring root subvolume from the blank image"

          btrfs subvolume snapshot /mnt/snapshots/root/blank /mnt/root

          echo "impermanence: unmounting base drive"

          umount /mnt

          echo "impermanence: done"
        '';
      };
    };

    extraModulePackages = [];
  };

  zramSwap.enable = true;

  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp34s0.useDHCP = lib.mkDefault true;

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
