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
    kernelPackages = pkgs.linuxPackages_zen;
    kernelModules = [ "kvm-amd" ];
    kernelParams = [
      "amd_pstate=active"
    ];
    kernel.sysctl = {
      "vm.max_map_count" = 2147483642;
    };

    initrd = {
      availableKernelModules = [
        "nvme"
        "xhci_pci"
        "ahci"
        "thunderbolt"
        "usb_storage"
        "usbhid"
        "sd_mod"
      ];

      kernelModules = [ "amdgpu" ];

      # Required for btrfs rollback
      systemd.enable = true;
    };

    extraModulePackages = [ ];
  };

  zramSwap.enable = true;

  networking.useDHCP = lib.mkDefault true;

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
