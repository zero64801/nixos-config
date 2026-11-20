# What the tests of a session share: a machine with libvirt and vm-inspect, a user who may open a guest, and a guest that runs the agent.
{
  host,
}:

let
  inherit (host) pkgs;
  inherit (pkgs) lib;

  # The network the guest gets when a test asks for one: the address of this side, which also answers for site.test.
  site = "10.9.9.1";
in
{
  name,
  # More tools for the path of a session, made of what the machine's inspect module offers, as its guestLibrary and its memprocfs.
  tools ? _: [ ],
  # What the test says of the machine beyond what is here.
  machine ? { },
  # A network device for the guest, on a network of libvirt's with this machine at the other end.
  network ? false,
  # A USB keyboard and a USB tablet of this machine's own, on a controller of their own, for a test to pass to the guest.
  usb ? false,
  # The lab's tools on the path of a session, instead of the guest tools alone.
  lab ? false,
  # Runs after the script below, and calls start_driven() where it wants the guest. A function of the nodes, or text.
  testScript,
}:

let
  # A guest with a screen and a keyboard that says on its serial port what was typed on its console, and that runs the agent whenever a channel for it is there.
  modules = pkgs.makeModulesClosure {
    rootModules = [
      "i8042"
      "atkbd"
      "virtio_pci"
      "virtio_console"
      "virtio_scsi"
      "sd_mod"
    ]
    ++ lib.optional network "virtio_net"
    ++ lib.optionals usb [
      "xhci_pci"
      "usbhid"
      "hid_generic"
      "input_leds"
    ];
    kernel = pkgs.linux.modules;
    firmware = pkgs.linux.modules;
  };
  loaded =
    lib.optionalString network " virtio_net"
    + lib.optionalString usb " xhci_pci usbhid hid_generic input_leds";
  # With curl, which speaks HTTP/3 too, and openssl, clients of TLS and QUIC that write their keys where SSLKEYLOGFILE and -keylogfile say.
  connected = lib.optionalString network ''
    ip link set lo up
    ip link set eth0 up
    ip addr add 10.9.9.50/24 dev eth0
    echo "nameserver ${site}" > /etc/resolv.conf
    ln -s ${pkgs.curl.bin}/bin/curl /bin/curl
    ln -s ${pkgs.openssl.bin}/bin/openssl /bin/openssl
  '';
  init = pkgs.writeScript "init" ''
    #!${pkgs.busybox}/bin/sh
    export PATH=${pkgs.busybox}/bin:/bin
    mount -t devtmpfs none /dev
    mount -t proc none /proc
    mount -t sysfs none /sys
    mkdir -p /run /tmp /bin /etc
    chmod 1777 /tmp
    ln -s ${pkgs.busybox}/bin/sh /bin/sh
    printf 'root:x:0:0:root:/:/bin/sh\ntester:x:1000:1000:tester:/tmp:/bin/sh\n' > /etc/passwd
    printf 'root:x:0:\ntester:x:1000:\n' > /etc/group
    printf '#!/bin/sh\nexec /bin/sh "$@"\n' > /bin/stands-in-for-python && chmod +x /bin/stands-in-for-python
    ${pkgs.kmod}/bin/modprobe -d ${modules} -a i8042 atkbd virtio_pci virtio_console virtio_scsi sd_mod${loaded}
    ${connected}(
      while :; do
        for port in /sys/class/virtio-ports/*; do
          if [ "$(cat "$port/name" 2>/dev/null)" = org.qemu.guest_agent.0 ]; then
            ${pkgs.qemu_kvm.ga}/bin/qemu-ga --method=virtio-serial --path="/dev/''${port##*/}" --statedir=/run
          fi
        done
        sleep 0.2
      done
    ) &
    echo "guest ready" > /dev/ttyS0
    while read -r line < /dev/tty1; do
      echo "typed: $line" > /dev/ttyS0
    done
  '';
  initrd = pkgs.makeInitrd {
    contents = [
      {
        object = init;
        symlink = "/init";
      }
    ];
  };
  driven = pkgs.writeText "driven.xml" ''
    <domain type="@TYPE@">
      <name>driven</name>
      <memory unit="MiB">1024</memory>
      <memoryBacking><source type="memfd"/><access mode="shared"/></memoryBacking>
      <vcpu>1</vcpu>
      <os>
        <type arch="x86_64" machine="q35">hvm</type>
        <kernel>/var/lib/driven/kernel</kernel>
        <initrd>/var/lib/driven/initrd</initrd>
        <cmdline>console=ttyS0 quiet</cmdline>
      </os>
      <features><acpi/></features>
      <seclabel type="static" model="dac" relabel="yes"><label>vm-guest:vm-guest</label></seclabel>
      <devices>
        <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
        <serial type="file"><source path="/var/lib/driven/serial.log"/></serial>
        <controller type="virtio-serial"/>
        <controller type="scsi" model="virtio-scsi"/>
        <video><model type="vga"/></video>
        <input type="tablet" bus="usb"/>
        <memballoon model="none"/>${
          lib.optionalString usb ''

            <controller type="usb" model="qemu-xhci"/>''
          + lib.optionalString network ''

            <interface type="network">
              <source network="lab"/>
              <mac address="52:54:00:00:00:32"/>
              <model type="virtio"/>
              <driver name="vhost" queues="2"/>
              <target dev="vm-driven"/>
            </interface>''
        }
      </devices>
    </domain>
  '';

  # Isolated, with this machine at 10.9.9.1 and dnsmasq answering for site.test, as libvirt's networks are set up.
  labNetwork = pkgs.writeText "lab.xml" ''
    <network>
      <name>lab</name>
      <bridge name="virbr9"/>
      <ip address="${site}" netmask="255.255.255.0"/>
      <dns><host ip="${site}"><hostname>site.test</hostname></host></dns>
    </network>
  '';
in
host.boot {
  inherit name;

  machines.machine = {
    # Set only when asked, since the lab is optional and its option may not exist.
    imports = [ machine ] ++ lib.optional lab { my.virtualisation.lab.enable = true; };

    virtualisation.memorySize = pkgs.lib.mkDefault 3072;
    virtualisation.cores = 2;
    # vhost, as the guests this is for have, moves frames past QEMU, which is what a capture has to cope with.
    boot.kernelModules = [
      "kvm-amd"
      "kvm-intel"
    ]
    ++ lib.optional network "vhost_net";

    virtualisation.libvirtd.enable = true;
    security.polkit.enable = true;
    security.polkit.enablePkexecWrapper = true;
    # Stands in for the administrator's approval, which alice gets and no other user does.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.policykit.exec" && subject.user == "alice") {
          return polkit.Result.YES;
        }
      });
    '';

    my.virtualisation.inspect = {
      enable = true;
      domains = [ "driven" ];
    };

    users.users = {
      alice = {
        uid = 1000;
        linger = true;
      };
      vm-guest = {
        isSystemUser = true;
        group = "vm-guest";
      };
    };
    users.groups.vm-guest = { };

    networking.firewall.trustedInterfaces = lib.mkIf network [ "virbr9" ];
    virtualisation.qemu.options = lib.mkIf usb [
      "-device qemu-xhci,id=labxhci"
      "-device usb-kbd,bus=labxhci.0,id=labkbd"
      "-device usb-tablet,bus=labxhci.0,id=labtablet"
    ];
  };

  testScript =
    { nodes, ... }:
    ''
      import re
      import shlex


      def as_user(name, uid, command):
          return f"su {name} -c " + shlex.quote(f"export XDG_RUNTIME_DIR=/run/user/{uid}; {command}")


      def alice(command):
          return as_user("alice", 1000, command)


      # The module puts vm-inspect alone on the path. The guest tools come with whatever wraps a session, which this stands in for.
      def lab(command):
          return alice(f"export PATH=${
            pkgs.lib.makeBinPath (
              [
                (
                  if lab then
                    nodes.machine.system.build.vmLabTools
                  else
                    nodes.machine.my.virtualisation.inspect.guestTools
                )
              ]
              ++ tools nodes.machine.my.virtualisation.inspect
            )
          }:$PATH; {command}")


      def session(options, script):
          return lab(f"vm-inspect {options} driven -- sh -c {shlex.quote('{ ' + script + '; } 2>&1')}")


      def start_driven():
          machine.succeed(
              "install -d /var/lib/driven && cp ${pkgs.linux}/bzImage /var/lib/driven/kernel && cp ${initrd}/initrd /var/lib/driven/initrd",
              f"sed 's/@TYPE@/{'kvm' if kvm else 'qemu'}/' ${driven} > /tmp/driven.xml && virsh define /tmp/driven.xml && virsh start driven",
          )
          machine.wait_until_succeeds("grep -q 'guest ready' /var/lib/driven/serial.log", timeout=300)


      machine.wait_for_unit("libvirtd.service")
      machine.wait_for_unit("user@1000.service")
      kvm = machine.execute("test -e /dev/kvm")[0] == 0${lib.optionalString network ''

        machine.succeed("virsh net-define ${labNetwork} && virsh net-start lab")''}
      print("nested KVM:", kvm)

    ''
    + (if lib.isFunction testScript then testScript { inherit nodes; } else testScript);
}
