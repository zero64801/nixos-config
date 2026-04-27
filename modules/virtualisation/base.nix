{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption concatStringsSep optional optionals optionalString;
  inherit (lib.types) bool listOf str;

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

    networkIsolation = {
      enable = mkOption {
        type = bool;
        default = true;
        description = ''
          Isolate VMs on the libvirt default network from the host's
          LAN, router, and host services. VMs still reach the public
          internet via NAT and get DHCP/DNS from the libvirt bridge.

          When disabled, virbr0 is added to firewall.trustedInterfaces
          (libvirt's default) — VMs can reach everything.
        '';
      };

      bridge = mkOption {
        type = str;
        default = "virbr0";
        description = "Libvirt bridge interface name.";
      };

      vmSubnet = mkOption {
        type = str;
        default = "192.168.122.0/24";
        description = "Subnet of the libvirt default network.";
      };

      lanRanges = mkOption {
        type = listOf str;
        default = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
        ];
        description = ''
          RFC1918 ranges to block from VMs (your LAN, router, NAS, etc.).
          The vmSubnet is excepted automatically so intra-VM traffic works.
        '';
      };

      allowHost = mkOption {
        type = bool;
        default = false;
        description = ''
          Allow VMs to reach host services beyond DHCP/DNS. Leave off
          for maximum isolation; turn on if a VM needs e.g. SSH to host.
        '';
      };
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

      # If isolation is OFF, replicate libvirt's "trust the bridge" default.
      # If ON, virbr0 is NOT trusted; the explicit firewall rules below
      # provide DHCP/DNS access only and block everything else.
      networking.firewall.trustedInterfaces =
        lib.optional (!cfg.networkIsolation.enable) cfg.networkIsolation.bridge;

      networking.firewall.allowedTCPPorts = mkIf cfg.openSpicePort [ 5900 ];

      # ── Network isolation: keep VM internet, block VM → LAN/host ──
      #
      # INPUT side (VM → host services):
      # nixos-fw default-drops anything from virbr0 (since we removed it
      # from trustedInterfaces). Just punch holes for DHCP + DNS so the
      # libvirt dnsmasq still works. Anything else from VM to host gets
      # default-dropped — exactly what we want.
      networking.firewall.interfaces.${cfg.networkIsolation.bridge} = mkIf cfg.networkIsolation.enable {
        allowedUDPPorts = [ 53 67 ];
        allowedTCPPorts = [ 53 ];
      };

      # FORWARD side (VM → LAN, VM → DNAT'd host services):
      # nixos-fw forward chain has a built-in `ct status dnat accept`
      # that whitelists ALL port-forwarded traffic — so VMs can reach
      # any container/netns service via DNAT. To beat it, install our
      # drop rules in a SEPARATE nftables table at HIGHER priority
      # (lower number) so they run BEFORE nixos-fw's accept.
      networking.nftables.enable = mkIf cfg.networkIsolation.enable true;

      networking.nftables.tables.vm-isolation = mkIf cfg.networkIsolation.enable {
        family = "inet";
        content =
          let
            bridge   = cfg.networkIsolation.bridge;
            vmSubnet = cfg.networkIsolation.vmSubnet;
            dropRule = range: ''
              iifname "${bridge}" ip saddr ${vmSubnet} ip daddr ${range} ip daddr != ${vmSubnet} drop
            '';
            rules = concatStringsSep "" (map dropRule cfg.networkIsolation.lanRanges);
          in
          ''
            chain forward {
              type filter hook forward priority -100; policy accept;
              ${rules}
            }
          '';
      };

      systemd.services.libvirtd.postStart = ''
        ${pkgs.libvirt}/bin/virsh net-start default || true
      '';

      # libvirtd-config is Type=oneshot which exits immediately, becoming
      # `inactive (dead)`. NixOS's switch-to-configuration only restarts
      # ACTIVE units when restartTriggers change, so inactive oneshots
      # are skipped — meaning hook/vhostUserPackages edits never apply.
      #
      # Fix: RemainAfterExit=yes keeps the unit "active" after success,
      # so restartTriggers actually fire on rebuild.
      systemd.services.libvirtd-config = {
        serviceConfig.RemainAfterExit = true;
        restartTriggers =
          config.virtualisation.libvirtd.qemu.vhostUserPackages;
      };

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
        {
          directory = "/var/lib/swtpm-localca";
          user = "tss";
          group = "tss";
          mode = "0750";
        }
      ];
    }
  ]);
}
