{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) literalExpression mkEnableOption mkIf mkMerge mkOption concatStringsSep;
  inherit (lib.types) attrsOf enum int listOf path str;

  cfg = config.nyx.virtualisation.desktop;
  gpuSwitchCfg = cfg.gpuSwitch;
in
{
  options.nyx.virtualisation.desktop = {
    vfio = {
      enable = mkEnableOption "VFIO/IOMMU GPU passthrough support";

      ids = mkOption {
        type = listOf str;
        default = [ ];
        description = "PCI device IDs to bind to vfio-pci driver";
        example = [
          "10de:1b80"
          "10de:10f0"
        ];
      };

      pciAddresses = mkOption {
        type = listOf str;
        default = [ ];
        description = "PCI bus addresses to detach for passthrough";
        example = [
          "01:00.0"
          "01:00.1"
        ];
      };
    };

    singleGpuPassthrough.enable = mkEnableOption "single-GPU passthrough mode";

    looking-glass = {
      enable = mkEnableOption "Looking Glass (kvmfr) support";

      staticSizeMb = mkOption {
        type = int;
        default = 32;
        description = "Static size in MB for the kvmfr module";
      };
    };

    hooks = mkOption {
      type = attrsOf path;
      default = { };
      description = "Libvirt hooks for VM lifecycle management";
      example = literalExpression ''
        {
          win11 = ./win11-hook.sh;
        }
      '';
    };

    gpuSwitch = {
      enable = mkEnableOption "GPU switching support";
      defaultMode = mkOption {
        type = enum [ "integrated" "hybrid" "nvidia" "vfio" ];
        default = "hybrid";
        description = "Default GPU mode";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.vfio.enable {
      boot.initrd.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
      ];

      # Only bind vfio-pci at boot if gpuSwitch is off or defaultMode is vfio
      nyx.virtualisation.base.extraModprobeConfigLines =
        mkIf (cfg.vfio.ids != [ ] && (!gpuSwitchCfg.enable || gpuSwitchCfg.defaultMode == "vfio"))
          [
            "options vfio-pci ids=${concatStringsSep "," cfg.vfio.ids}"
          ];

      nyx.virtualisation.base.cgroupDeviceACL = [ "/dev/vfio/vfio" ];
    })

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

    {
      virtualisation.libvirtd.hooks.qemu = mkIf (cfg.hooks != { }) cfg.hooks;
      virtualisation.spiceUSBRedirection.enable = true;
      environment.systemPackages = [ pkgs.spice-gtk ];
    }
  ];
}
