{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption concatStringsSep optional optionals optionalString;
  inherit (lib.types) bool lines listOf port str;

  cfg = config.my.virtualisation.base;
  isolation = cfg.networkIsolation;

  # Keeping the name, uuid and bridge mac of libvirt's own default network: a redefine under a different uuid is refused, and domains reference the network by name.
  defaultNetwork = pkgs.writeText "libvirt-default-network.xml" ''
    <network>
      <name>default</name>
      <uuid>d9261a02-4010-40bc-b148-0648d3639cf0</uuid>
      <forward mode="nat">
        <nat>
          <port start="1024" end="65535"/>
        </nat>
      </forward>
      <bridge name="${isolation.bridge}" stp="on" delay="0"/>
      <mac address="52:54:00:37:86:50"/>
      <port isolated="yes"/>
      <ip address="192.168.122.1" netmask="255.255.255.0">
        <dhcp>
          <range start="192.168.122.2" end="192.168.122.254"/>
        </dhcp>
      </ip>
    </network>
  '';

  portSet = ports: "{ ${concatStringsSep ", " (map toString ports)} }";
in
{
  options.my.virtualisation.base = {
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

      extraInputRules = mkOption {
        type = lines;
        default = "";
        description = ''
          nftables rules placed before the final drop of the chain that decides what guests may reach on the host.
          Packets arriving here already passed the DHCP, DNS and allowedHost* accepts.
        '';
      };

      interGuest = mkOption {
        type = bool;
        default = false;
        description = ''
          Let guests on the bridge reach each other. Off defines the
          libvirt default network with <port isolated='yes'/>, so one
          compromised guest cannot scan or attack the others.
        '';
      };

      allowedHostTCPPorts = mkOption {
        type = listOf port;
        default = [ ];
        description = ''
          Extra TCP ports on the host that VMs may reach while network
          isolation is enabled. DHCP and DNS are always allowed.
        '';
      };

      allowedHostUDPPorts = mkOption {
        type = listOf port;
        default = [ ];
        description = ''
          Extra UDP ports on the host that VMs may reach while network
          isolation is enabled. DHCP and DNS are always allowed.
        '';
      };

      allowedLanHosts = mkOption {
        type = listOf str;
        default = [ ];
        description = ''
          LAN or other-subnet destinations (IP or CIDR) that VMs may
          reach despite isolation, punched through ahead of the lanRanges
          drops. Use for e.g. a device on an isolated IoT VLAN you adb
          into from a VM. Actual reachability is still gated by the
          router's own inter-VLAN rules.
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

      my.virtualisation.base.cgroupDeviceACL = [
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

      networking.firewall.trustedInterfaces =
        lib.optional (!cfg.networkIsolation.enable || cfg.networkIsolation.allowHost) cfg.networkIsolation.bridge;

      networking.firewall.allowedTCPPorts = mkIf cfg.openSpicePort [ 5900 ];

      networking.firewall.interfaces.${cfg.networkIsolation.bridge} = mkIf cfg.networkIsolation.enable {
        allowedUDPPorts = [ 53 67 ] ++ cfg.networkIsolation.allowedHostUDPPorts;
        allowedTCPPorts = [ 53 ] ++ cfg.networkIsolation.allowedHostTCPPorts;
      };

      # restart = false: nixvirt destroys (hard powers off) every domain on a network it restarts, and the isolated flag is applied when a guest's tap joins the bridge anyway, so it takes effect for domains started after the next network start.
      virtualisation.libvirt.connections."qemu:///system".networks = mkIf (!isolation.interGuest) [
        {
          definition = defaultNetwork;
          active = true;
          restart = false;
        }
      ];

      # nixos-fw's forward chain accepts all DNAT'd traffic via `ct status dnat accept`, so the drops live in a separate table at a lower priority number to run first.
      networking.nftables.enable = mkIf cfg.networkIsolation.enable true;

      networking.nftables.tables.vm-isolation = mkIf cfg.networkIsolation.enable {
        family = "inet";
        content =
          let
            bridge   = isolation.bridge;
            vmSubnet = isolation.vmSubnet;
            allowRule = dst: ''
              iifname "${bridge}" ip saddr ${vmSubnet} ip daddr ${dst} accept
            '';
            allows = concatStringsSep "" (map allowRule isolation.allowedLanHosts);
            dropRule = range: ''
              iifname "${bridge}" ip saddr ${vmSubnet} ip daddr ${range} ip daddr != ${vmSubnet} drop
            '';
            rules = concatStringsSep "" (map dropRule isolation.lanRanges);

            # The firewall's own port lists apply to every interface, so host services open to the LAN are open to guests too. Dropping here, at a lower priority number, is final and needs no coordination with whatever a module opens.
            hostTcp = [ 53 ] ++ isolation.allowedHostTCPPorts;
            hostUdp = [ 53 67 ] ++ isolation.allowedHostUDPPorts;
          in
          ''
            chain forward {
              type filter hook forward priority -100; policy accept;
              ${allows}${rules}
            }

            chain input {
              type filter hook input priority -100; policy accept;
              iifname != "${bridge}" accept
              ct state established,related accept
              tcp dport ${portSet hostTcp} accept
              udp dport ${portSet hostUdp} accept
              icmp type echo-request accept
              ${isolation.extraInputRules}
              ${optionalString isolation.allowHost "accept"}
              drop
            }
          '';
      };

      systemd.services.libvirtd.postStart = ''
        ${pkgs.libvirt}/bin/virsh net-start default || true
      '';

      # switch-to-configuration skips inactive oneshots, so without RemainAfterExit the restartTriggers never fire and hook edits never apply.
      systemd.services.libvirtd-config = {
        serviceConfig.RemainAfterExit = true;
        restartTriggers =
          config.virtualisation.libvirtd.qemu.vhostUserPackages;
      };

      # libvirtd is left out: the libvirtd module's polkit rule gives that group domain definition with host disks, so root, with no prompt.
      my.security.serviceAdminGroups = [
        "kvm"
      ]
      ++ optional cfg.enableVirgl "render";

      # Read before that rule, so even a member of the group is asked for the key.
      security.polkit.extraConfig = lib.mkBefore ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.libvirt.unix.manage") {
            return polkit.Result.AUTH_ADMIN;
          }
        });
      '';

      environment.systemPackages =
        with pkgs;
        [
          virt-manager
          virt-viewer
        ]
        ++ optionals cfg.enableVirgl [ virglrenderer ];

      boot.extraModprobeConfig = concatStringsSep "\n" cfg.extraModprobeConfigLines;

      my.persistence.directories = [
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
