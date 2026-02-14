{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption concatStringsSep optional optionals optionalString;
  inherit (lib.types) listOf str;

  cfg = config.nyx.virtualisation.base;
in
{
  options.nyx.virtualisation.base = {
    enable = mkEnableOption "base KVM/QEMU/Libvirt support";

    openSpicePort = mkEnableOption "connection to Spice through remote-viewer";

    enableVirgl = mkEnableOption "VirGL renderer for 3D acceleration in virtual machines";

    extraModprobeConfigLines = mkOption {
      type = listOf str;
      default = [ ];
      description = "Additional lines to add to boot.extraModprobeConfig";
    };

    cgroupDeviceACL = mkOption {
      type = listOf str;
      default = [ ];
      description = "Device paths to allow in the QEMU cgroup device ACL";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
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

      networking.firewall.trustedInterfaces = [ "virbr0" ];
      networking.firewall.allowedTCPPorts = mkIf cfg.openSpicePort [ 5900 ];

      systemd.services.libvirtd.postStart = ''
        ${pkgs.libvirt}/bin/virsh net-start default || true
      '';

      nyx.security.serviceAdminGroups = [
        "libvirtd"
        "kvm"
      ]
      ++ optional cfg.enableVirgl "render";

      environment.systemPackages =
        with pkgs;
        [
          virt-manager
          virt-viewer
        ]
        ++ optionals cfg.enableVirgl [ virglrenderer ];

      boot.extraModprobeConfig = concatStringsSep "\n" cfg.extraModprobeConfigLines;

      nyx.persistence.directories = [
        {
          directory = "/var/lib/libvirt";
          user = "root";
          group = "libvirtd";
          mode = "0770";
        }
      ];
    }
  ]);
}
