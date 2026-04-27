{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) literalExpression mkEnableOption mkIf mkMerge mkOption concatStringsSep;
  inherit (lib.types) attrsOf int listOf path str;

  cfg = config.nyx.virtualisation.desktop;
  gpuSwitchCfg = config.nyx.virtualisation.gpuSwitch;
in
{
  options.nyx.virtualisation.desktop = {
    enable = mkEnableOption "desktop virtualisation features (vfio, looking-glass, libvirt hooks)";

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

      escapeKey = mkOption {
        type = str;
        default = "KEY_RIGHTCTRL";
        description = "Looking Glass escape key (Linux input event keycode).";
      };

      extraClientConfig = mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]));
        default = { };
        description = ''
          Extra sections/keys merged into ~/.config/looking-glass/client.ini.
          Example: { spice.enable = false; win.fullScreen = true; }
        '';
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
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.vfio.enable {
      boot.initrd.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
      ];

      boot.kernelParams = [
        "amd_iommu=force_enable"
        "iommu=pt"
        "kvm.ignore_msrs=1"
      ];

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

      hm.xdg.configFile."looking-glass/client.ini".text =
        # Note: do NOT persist ~/.config/looking-glass — bind mount would
        # hide this HM-managed client.ini. The LG client's runtime files
        # (imgui.ini, presets/) are trivial UI prefs that regenerate.
        let
          baseConfig = {
            app = {
              shmFile = "/dev/kvmfr0";
            };
            input = {
              escapeKey = cfg.looking-glass.escapeKey;
              rawMouse = true;
              ignoreWindowsKeys = true;
            };
            win = {
              fullScreen = false;
              autoResize = true;
              keepAspect = true;
              quickSplash = true;
            };
            spice = {
              enable = true;
              clipboard = true;
              audio = true;
            };
          };
          merged = lib.recursiveUpdate baseConfig cfg.looking-glass.extraClientConfig;
          renderValue = v:
            if builtins.isBool v then (if v then "yes" else "no")
            else toString v;
          renderSection = name: kvs:
            "[${name}]\n" +
            (lib.concatStringsSep "\n"
              (lib.mapAttrsToList (k: v: "${k}=${renderValue v}") kvs)) +
            "\n";
        in
        lib.concatStringsSep "\n"
          (lib.mapAttrsToList renderSection merged);
    })

    {
      # Wrap user-provided hook paths via writeShellScript so they're
      # always executable regardless of the source file's mode bits.
      # libvirt silently skips non-executable hooks ("Non-executable
      # hook script" warning), which is a nasty failure mode.
      virtualisation.libvirtd.hooks.qemu = mkIf (cfg.hooks != { }) (
        lib.mapAttrs (name: src:
          pkgs.writeShellScript "libvirt-hook-${name}" (builtins.readFile src)
        ) cfg.hooks
      );
      virtualisation.spiceUSBRedirection.enable = true;
      environment.systemPackages = [ pkgs.spice-gtk ];

      systemd.services.libvirtd-config.restartTriggers =
        mkIf (cfg.hooks != { }) (lib.attrValues cfg.hooks);
    }
  ]);
}
