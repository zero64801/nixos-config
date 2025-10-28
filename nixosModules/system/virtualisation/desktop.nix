{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

{
  options.nyx.virtualisation.desktop = {
    vfio.enable = mkEnableOption "VFIO/IOMMU GPU passthrough support.";
    vfio.ids = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of PCI device IDs to bind to the vfio-pci driver.";
      example = [ "1111:1111" "2222:2222" ];
    };
    singleGpuPassthrough.enable = mkEnableOption "Enable single-GPU passthrough mode.";
    vfio.pciAddresses = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of PCI bus addresses (e.g., '01:00.0') to detach for passthrough.";
      example = [ "01:00.0" "01:00.1" ];
    };

    looking-glass.enable = mkEnableOption "Looking Glass (kvmfr) support.";
    looking-glass.staticSizeMb = mkOption {
      type = types.int;
      default = 32;
      description = "Static size in MB for the kvmfr module.";
    };

    hooks = mkOption {
      type = types.attrsOf types.path;
      default = {};
      description = "An attribute set of libvirt hooks, where the key is the hook name and the value is the path to the script.";
    };
  };

  config = {
    # --- VFIO CONFIGURATION ---
    boot.initrd.kernelModules = mkIf config.nyx.virtualisation.desktop.vfio.enable [
      "vfio_pci" "vfio" "vfio_iommu_type1"
    ];

    # --- LOOKING GLASS CONFIGURATION ---
    boot.kernelModules = mkIf config.nyx.virtualisation.desktop.looking-glass.enable [ "kvmfr" ];
    boot.extraModulePackages = mkIf config.nyx.virtualisation.desktop.looking-glass.enable [ config.boot.kernelPackages.kvmfr ];
    services.udev.extraRules = mkIf config.nyx.virtualisation.desktop.looking-glass.enable ''
      SUBSYSTEM=="kvmfr", OWNER="qemu-libvirtd", GROUP="kvm", MODE="0660"
    '';

    nyx.virtualisation.base.extraModprobeConfigLines =
      (optionals (config.nyx.virtualisation.desktop.vfio.ids != []) [
        "options vfio-pci ids=${concatStringsSep "," config.nyx.virtualisation.desktop.vfio.ids}"
      ])
      ++
      (optionals config.nyx.virtualisation.desktop.looking-glass.enable [
        "options kvmfr static_size_mb=${toString config.nyx.virtualisation.desktop.looking-glass.staticSizeMb}"
      ]);

    nyx.virtualisation.base.cgroupDeviceACL =
      (optionals config.nyx.virtualisation.desktop.vfio.enable [
        "/dev/vfio/vfio"
      ])
      ++
      (optionals config.nyx.virtualisation.desktop.looking-glass.enable [
        "/dev/kvmfr0"
      ]);

    virtualisation.libvirtd.hooks.qemu = config.nyx.virtualisation.desktop.hooks;
    virtualisation.spiceUSBRedirection.enable = true;
    environment.systemPackages = with pkgs; [
      spice-gtk
      looking-glass-client
    ];
  };
}
