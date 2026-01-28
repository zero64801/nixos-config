{
  config,
  lib,
  options,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.nyx.virtualisation.base;
in
{
  options.nyx.virtualisation.base = {
    enable = mkEnableOption "base KVM/QEMU/Libvirt support";

    openSpicePort = mkEnableOption "connection to Spice through remote-viewer";

    enableVirgl = mkEnableOption "VirGL renderer for 3D acceleration in virtual machines";

    extraModprobeConfigLines = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional lines to add to boot.extraModprobeConfig";
    };

    cgroupDeviceACL = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Device paths to allow in the QEMU cgroup device ACL";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Core Libvirt daemon
      virtualisation.libvirtd = {
        enable = true;
        onBoot = "ignore";
        onShutdown = "shutdown";

        qemu = {
          package = pkgs.qemu_kvm;
          runAsRoot = false;
          swtpm.enable = true;

          verbatimConfig = ''
            cgroup_device_acl = [
              ${concatStringsSep ",\n    " (map (path: ''"${path}"'') cfg.cgroupDeviceACL)}
            ]
          ''
          + optionalString cfg.enableVirgl ''
            spice_gl = 1
            spice_rendernode = "/dev/dri/renderD128"
          '';
        };
      };

      # Default cgroup device ACL
      nyx.virtualisation.base.cgroupDeviceACL = [
        "/dev/null"
        "/dev/full"
        "/dev/zero"
        "/dev/random"
        "/dev/urandom"
        "/dev/ptmx"
        "/dev/kvm"
        "/dev/rtc"
        "/dev/hpet"
      ]
      ++ optionals cfg.enableVirgl [
        "/dev/dri/card0"
        "/dev/dri/renderD128"
      ];

      # Trust the virtual network interface
      networking.firewall.trustedInterfaces = [ "virbr0" ];

      # Open Spice port if requested
      networking.firewall.allowedTCPPorts = mkIf cfg.openSpicePort [ 5900 ];

      # Ensure default network starts
      systemd.services.libvirtd.postStart = ''
        ${pkgs.libvirt}/bin/virsh net-start default || true
      '';

      # Add users to required groups
      nyx.security.serviceAdminGroups = [
        "libvirtd"
        "kvm"
      ]
      ++ optional cfg.enableVirgl "render";

      # Package management
      environment.systemPackages =
        with pkgs;
        [
          virt-manager
          virt-viewer
        ]
        ++ optionals cfg.enableVirgl [ virglrenderer ];

      # Apply modprobe configuration
      boot.extraModprobeConfig = concatStringsSep "\n" cfg.extraModprobeConfigLines;
    }

    # Persist libvirt state across reboots (impermanence)
    (mkIf config.nyx.impermanence.enable {
      environment.persistence.${config.nyx.impermanence.persistentStoragePath}.directories = [
        {
          directory = "/var/lib/libvirt";
          user = "root";
          group = "libvirtd";
          mode = "0770";
        }
      ];
    })
  ]);
}
