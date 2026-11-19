# nix build --no-link -L .#tests.virtualisation.nixvirt-snapshot-freeze
{
  host,
}:

let
  inherit (host) pkgs;

  # A guest with a filesystem on a disk and an agent that says on the serial port what it is asked to do.
  modules = pkgs.makeModulesClosure {
    rootModules = [
      "virtio_pci"
      "virtio_console"
      "virtio_scsi"
      "sd_mod"
      "ext4"
    ];
    kernel = pkgs.linux.modules;
    firmware = pkgs.linux.modules;
  };
  init = pkgs.writeScript "init" ''
    #!${pkgs.busybox}/bin/sh
    export PATH=${pkgs.busybox}/bin
    mount -t devtmpfs none /dev
    mount -t proc none /proc
    mount -t sysfs none /sys
    mkdir -p /run /mnt
    ${pkgs.kmod}/bin/modprobe -d ${modules} -a virtio_pci virtio_console virtio_scsi sd_mod ext4
    until [ -b /dev/sda ]; do sleep 0.2; done
    mke2fs -q /dev/sda && mount -t ext4 /dev/sda /mnt && echo kept > /mnt/file
    (
      while :; do
        for port in /sys/class/virtio-ports/*; do
          if [ "$(cat "$port/name" 2>/dev/null)" = org.qemu.guest_agent.0 ]; then
            ${pkgs.qemu_kvm.ga}/bin/qemu-ga --verbose --method=virtio-serial --path="/dev/''${port##*/}" --statedir=/run 2>&1 | grep fsfreeze > /dev/ttyS0
          fi
        done
        sleep 0.2
      done
    ) &
    echo "guest ready: $(cat /mnt/file)" > /dev/ttyS0
    while :; do sleep 3600; done
  '';
  initrd = pkgs.makeInitrd {
    contents = [
      {
        object = init;
        symlink = "/init";
      }
    ];
  };
  domain =
    name: devices:
    pkgs.writeText "${name}.xml" ''
      <domain type="@TYPE@">
        <name>${name}</name>
        <memory unit="MiB">512</memory>
        <vcpu>1</vcpu>
        <os>
          <type arch="x86_64" machine="q35">hvm</type>
          <kernel>/var/lib/guests/kernel</kernel>
          <initrd>/var/lib/guests/initrd</initrd>
          <cmdline>console=ttyS0 quiet</cmdline>
        </os>
        <features><acpi/></features>
        <devices>
          <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
          <serial type="file"><source path="/var/lib/guests/${name}.log"/></serial>
          <controller type="scsi" model="virtio-scsi"/>
          <disk type="file" device="disk">
            <driver name="qemu" type="qcow2"/>
            <source file="/var/lib/guests/${name}.qcow2"/>
            <target dev="sda" bus="scsi"/>
          </disk>
          <memballoon model="none"/>
          ${devices}
        </devices>
      </domain>
    '';
  # One whose agent can be reached once it is given a channel, and one that has nothing to plug a channel into.
  heard = domain "heard" ''<controller type="virtio-serial"/>'';
  deaf = domain "deaf" "";
in
host.boot {
  name = "nixvirt-snapshot-freeze";

  machines.machine = {
    my.virtualisation.nixvirt.enable = true;
    virtualisation.libvirtd.enable = true;
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
  };

  testScript = ''
    machine.wait_for_unit("libvirtd.service")
    kind = "kvm" if machine.execute("test -e /dev/kvm")[0] == 0 else "qemu"
    machine.succeed("install -d /var/lib/guests && cp ${pkgs.linux}/bzImage /var/lib/guests/kernel && cp ${initrd}/initrd /var/lib/guests/initrd")
    for name, xml in [("heard", "${heard}"), ("deaf", "${deaf}")]:
        machine.succeed(
            f"qemu-img create -f qcow2 /var/lib/guests/{name}.qcow2 64M",
            f"sed 's/@TYPE@/{kind}/' {xml} > /tmp/{name}.xml && virsh define /tmp/{name}.xml && virsh start {name}",
        )
    for name in ["heard", "deaf"]:
        machine.wait_until_succeeds(f"grep -q 'guest ready: kept' /var/lib/guests/{name}.log", timeout=300)


    # How often the guest's agent was told to freeze, and whether it took commands again afterwards, which it does once thawed.
    def frozen(name):
        said = machine.succeed(f"cat /var/lib/guests/{name}.log")
        return said.count('{"execute":"guest-fsfreeze-freeze"}'), said.count("enabling command: guest-fsfreeze-freeze-list")


    with subtest("a running guest's agent freezes its filesystems for a snapshot, through a channel it has for just that long"):
        machine.fail("virsh dumpxml heard | grep -q guest_agent")
        out = machine.succeed("nixvirt-snapshot create -y heard first 2>&1")
        print(out)
        assert "its filesystems held still for the snapshot" in out, out
        assert frozen("heard") == (1, 1), frozen("heard")
        machine.fail("virsh dumpxml heard | grep -q guest_agent")
        assert machine.succeed("virsh snapshot-list heard --name").split() == ["first"]
        assert "heard.first" in machine.succeed("virsh domblklist heard")

    with subtest("--no-freeze leaves the guest alone"):
        out = machine.succeed("nixvirt-snapshot create -y --no-freeze heard second 2>&1")
        assert "held still" not in out and "no agent in the guest" not in out and "like a power cut" in out, out
        assert frozen("heard") == (1, 1), frozen("heard")
        out = machine.fail("nixvirt-snapshot list --no-freeze heard 2>&1")
        assert "only applies to create and rotate" in out, out

    with subtest("a rotated snapshot is taken with the filesystems frozen as well"):
        out = machine.succeed("nixvirt-snapshot rotate -y heard 2>&1")
        print(out)
        assert "its filesystems held still for the snapshot" in out, out
        assert frozen("heard") == (2, 2), frozen("heard")
        machine.fail("virsh dumpxml heard | grep -q guest_agent")

    with subtest("a guest no agent can be reached in gets the snapshot it always got, and is told so"):
        out = machine.succeed("nixvirt-snapshot create -y deaf first 2>&1")
        print(out)
        assert "no agent in the guest froze its filesystems" in out, out
        assert machine.succeed("virsh snapshot-list deaf --name").split() == ["first"]

    with subtest("a channel the guest already has is used and left where it is"):
        machine.succeed("virsh attach-device heard ${pkgs.writeText "own.xml" ''<channel type="unix"><source mode="bind"/><target type="virtio" name="org.qemu.guest_agent.0"/></channel>''} --live")
        out = machine.succeed("nixvirt-snapshot create -y heard third 2>&1")
        assert "its filesystems held still for the snapshot" in out, out
        assert frozen("heard") == (3, 3), frozen("heard")
        machine.succeed("virsh dumpxml heard | grep -q guest_agent")
        for name in ["heard", "deaf"]:
            assert machine.succeed(f"virsh domstate {name}").strip() == "running"
  '';
}
