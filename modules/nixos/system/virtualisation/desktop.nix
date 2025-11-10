{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.nyx.virtualisation.desktop;
  baseCfg = config.nyx.virtualisation.base;
in
{
  options.nyx.virtualisation.desktop = {
    vfio = {
      enable = mkEnableOption "VFIO/IOMMU GPU passthrough support";

      ids = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "PCI device IDs to bind to vfio-pci driver";
        example = [ "10de:1b80" "10de:10f0" ];
      };

      pciAddresses = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "PCI bus addresses to detach for passthrough";
        example = [ "01:00.0" "01:00.1" ];
      };
    };

    singleGpuPassthrough.enable = mkEnableOption "single-GPU passthrough mode";

    looking-glass = {
      enable = mkEnableOption "Looking Glass (kvmfr) support";

      staticSizeMb = mkOption {
        type = types.int;
        default = 32;
        description = "Static size in MB for the kvmfr module";
      };
    };

    hooks = mkOption {
      type = types.attrsOf types.path;
      default = { };
      description = "Libvirt hooks for VM lifecycle management";
      example = literalExpression ''
        {
          win11 = ./win11-hook.sh;
        }
      '';
    };
  };

  config = mkMerge [
    # VFIO Configuration
    (mkIf cfg.vfio.enable {
      boot.initrd.kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" ];

      nyx.virtualisation.base.extraModprobeConfigLines = mkIf (cfg.vfio.ids != [ ]) [
        "options vfio-pci ids=${concatStringsSep "," cfg.vfio.ids}"
      ];

      nyx.virtualisation.base.cgroupDeviceACL = [ "/dev/vfio/vfio" ];
    })

    # Looking Glass Configuration
    (mkIf cfg.looking-glass.enable {
      boot.kernelModules = [ "kvmfr" ];
      boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];

      services.udev.extraRules = ''
        SUBSYSTEM=="kvmfr", OWNER="qemu-libvirtd", GROUP="kvm", MODE="0660"
      '';

      nyx.virtualisation.base.extraModprobeConfigLines = [
        "options kvmfr static_size_mb=${toString cfg.looking-glass.staticSizeMb}"
      ];

      nyx.virtualisation.base.cgroupDeviceACL = [ "/dev/kvmfr0" ];

      environment.systemPackages = [ pkgs.looking-glass-client ];
    })

    # General Desktop Virtualization
    {
      virtualisation.libvirtd.hooks.qemu = mkIf (cfg.hooks != { }) cfg.hooks;
      virtualisation.spiceUSBRedirection.enable = true;
      environment.systemPackages = [ pkgs.spice-gtk ];
    }
  ];
}
