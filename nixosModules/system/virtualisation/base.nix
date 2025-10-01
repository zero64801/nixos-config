{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

{
  options.nyx.virtualisation.base = {
    enable = mkEnableOption "Enable base KVM/QEMU/Libvirt support.";
    openSpicePort = mkEnableOption "Enable connection to Spice through remote-viewer";
    enableVirgl = mkEnableOption "Enable VirGL renderer for 3D acceleration in virtual machines";
    extraModprobeConfigLines = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        A list of lines to be added to boot.extraModprobeConfig.
        Modules can contribute their required modprobe options to this list.
      '';
    };
    cgroupDeviceACL = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        A list of device paths to allow in the QEMU cgroup device ACL.
        Modules can contribute their required device paths to this list.
      '';
    };
  };

  config = mkIf config.nyx.virtualisation.base.enable {
    # Enable the core Libvirt daemon
    virtualisation.libvirtd.enable = true;

    # Configure QEMU with sane defaults
    virtualisation.libvirtd.qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = false; # More secure default
      swtpm.enable = true; # For Windows 11 TPM support
      ovmf.enable = true;
      ovmf.packages = [(pkgs.OVMFFull.override {
        secureBoot = true;
        tpmSupport = true;
      }).fd];
      verbatimConfig = ''
        cgroup_device_acl = [
          ${concatStringsSep ",\n" (map (path: ''"${path}"'') config.nyx.virtualisation.base.cgroupDeviceACL)}
        ]
      '';
    };

    nyx.virtualisation.base.cgroupDeviceACL = [
      "/dev/null" "/dev/full" "/dev/zero"
      "/dev/random" "/dev/urandom"
      "/dev/ptmx" "/dev/kvm" "/dev/kqemu"
      "/dev/rtc" "/dev/hpet"
    ] ++ optionals config.nyx.virtualisation.base.enableVirgl [
      "/dev/dri/renderD128"
    ];

    # Trust the interface created by this network.
    networking.firewall.trustedInterfaces = [ "virbr0" ];

    # Open port for connecting to spice
    networking.firewall.allowedTCPPorts = mkIf config.nyx.virtualisation.base.openSpicePort [ 5900 ];

    # Ensure the default network is always started.
    systemd.services.libvirtd.postStart = ''
      ${pkgs.libvirt}/bin/virsh net-start default || true
    '';

    nyx.security.serviceAdminGroups = [ "libvirtd" "kvm" ];
    nyx.impermanence = mkIf config.nyx.impermanence.enable {
      roots.${config.nyx.impermanence.mainPersistRoot} = {
        directories = [
          { directory = "/var/lib/libvirt"; user = "root"; group = "libvirtd"; mode = "0770"; }
        ];
        neededFor = [ "libvirtd.service" ];
      };
    };

    environment.systemPackages = with pkgs; [
      virt-manager
      virt-viewer
    ] ++ optionals config.nyx.virtualisation.base.enableVirgl [
      virglrenderer
    ];

    boot.extraModprobeConfig = concatStringsSep "\n" config.nyx.virtualisation.base.extraModprobeConfigLines;
  };
}
