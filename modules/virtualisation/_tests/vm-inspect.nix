# nix build --impure --no-link -L --expr 'import ./modules/virtualisation/_tests/vm-inspect.nix { }'
# vm-inspect against a real QEMU under libvirt, running as its own user with its memory on huge pages.
{
  pkgs ? (builtins.getFlake (toString ../../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  memprocfs = pkgs.callPackage ../../../pkgs/packages/memprocfs.nix { };

  # 5 GiB so that part of the memory lies above the hole below 4 GiB, where its place in the file and in the guest differ.
  domain =
    name: backing:
    pkgs.writeText "${name}.xml" ''
      <domain type="@TYPE@">
        <name>${name}</name>
        <memory unit="MiB">${if backing == "" then "256" else "5120"}</memory>
        ${backing}
        <vcpu>1</vcpu>
        <os><type arch="x86_64" machine="q35">hvm</type></os>
        <seclabel type="static" model="dac" relabel="yes"><label>vm-guest:vm-guest</label></seclabel>
        <devices>
          <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
          <memballoon model="none"/>
        </devices>
      </domain>
    '';

  shared = domain "guest" ''
    <memoryBacking><hugepages/><source type="memfd"/><allocation mode="immediate"/></memoryBacking>
  '';
  private = domain "plain" "";

  settings = pkgs.writeText "settings.json" (builtins.toJSON { domains = [ "guest" ]; });
in
pkgs.testers.runNixOSTest {
  name = "vm-inspect";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../inspect.nix ];

      virtualisation.memorySize = 8192;
      virtualisation.cores = 2;
      boot.kernelParams = [ "hugepages=2600" ];
      boot.kernelModules = [
        "kvm-amd"
        "kvm-intel"
      ];

      virtualisation.libvirtd.enable = true;
      security.polkit.enable = true;
      security.polkit.enablePkexecWrapper = true;
      # Stands in for the administrator's approval, which alice gets and eve does not.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.policykit.exec" && subject.user == "alice") {
            return polkit.Result.YES;
          }
        });
      '';

      my.virtualisation.inspect = {
        enable = true;
        domains = [
          "guest"
          "plain"
        ];
      };

      users.users = {
        alice = {
          isNormalUser = true;
          uid = 1000;
          linger = true;
        };
        eve = {
          isNormalUser = true;
          uid = 1001;
          linger = true;
        };
        vm-guest = {
          isSystemUser = true;
          group = "vm-guest";
        };
      };
      users.groups.vm-guest = { };

      environment.systemPackages = [
        pkgs.gdb
        pkgs.python3
      ];
    };

  testScript = ''
    import re
    import shlex

    LEECHCORE = "${memprocfs}/lib/memprocfs/leechcore.so"
    PROBE = "python3 -I ${./leechcore_probe.py}"


    def as_user(name, uid, command):
        return f"su {name} -c " + shlex.quote(f"export XDG_RUNTIME_DIR=/run/user/{uid}; {command}")


    def alice(command):
        return as_user("alice", 1000, command)


    def guest_bytes(address, count):
        dump = machine.succeed(f"virsh qemu-monitor-command guest --hmp 'xp /{count}xb {address:#x}'")
        return bytes(int(b, 16) for b in re.findall(r"0x([0-9a-f]{2})\b", dump))


    machine.wait_for_unit("libvirtd.service")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("user@1001.service")
    # There before any session, so a sandbox started earlier can have been given them.
    machine.succeed("test -d /run/vm-inspect && test -d /run/user/1000/vm-inspect")
    kvm = machine.execute("test -e /dev/kvm")[0] == 0
    print("nested KVM:", kvm)
    for xml in ["${shared}", "${private}"]:
        machine.succeed(f"sed 's/@TYPE@/{'kvm' if kvm else 'qemu'}/' {xml} > /tmp/domain.xml && virsh define /tmp/domain.xml")
    machine.succeed("virsh start guest && virsh start plain")
    print(machine.succeed("grep -E 'Uid|Umask' /proc/$(cat /run/libvirt/qemu/guest.pid)/status; ls -l /proc/$(cat /run/libvirt/qemu/guest.pid)/fd | grep -E 'memfd|huge'"))

    with subtest("memory written through LeechCore is the guest's own, below and above 4 GiB"):
        out = machine.succeed(alice(f"vm-inspect guest -- {PROBE} {LEECHCORE} 1000000=low-marker 120000000=high-marker 2>&1"))
        print(out)
        assert "probe ok" in out, out
        if kvm:
            assert "fallback" not in out, "the memory map did not come from the session"
        assert guest_bytes(0x1000000, 10) == b"low-marker"
        assert guest_bytes(0x120000000, 11) == b"high-marker"

    with subtest("the session leaves nothing behind"):
        machine.fail("ls /run/user/1000/vm-inspect/guest")
        assert machine.succeed("ls /run/vm-inspect").split() == ["guest.lock"]

    with subtest("a debugger reaches the guest through the session's socket, and no other user does"):
        out = machine.succeed(alice(
            "vm-inspect --gdb guest -- sh -c 'stat -c \"%U:%G %a\" $VM_INSPECT_GDB $(dirname $VM_INSPECT_GDB); "
            "gdb -batch -ex \"target remote $VM_INSPECT_GDB\" -ex \"info registers rip\" -ex detach 2>&1'"))
        print(out)
        assert re.search(r"^rip\s+0x", out, re.MULTILINE), out
        assert "vm-guest:vm-guest 760" in out and "vm-guest:root 750" in out, out
        assert machine.succeed("ls /run/vm-inspect").split() == ["guest.lock"]
        assert machine.succeed("virsh domstate guest").strip() == "running"
        machine.succeed(alice("vm-inspect --gdb guest -- sleep 30 >/dev/null 2>&1 &"))
        machine.wait_until_succeeds("ls /run/vm-inspect/guest.*/gdb.sock", timeout=20)
        machine.fail("su eve -c 'ls /run/vm-inspect/guest.*/'")

    with subtest("a guest is open to one session at a time"):
        out = machine.fail(alice("vm-inspect guest -- true 2>&1"))
        assert "already open for inspection" in out, out

    with subtest("another program of the same user joins the open session, with no approval and no second opening"):
        out = machine.succeed(alice(f"vm-inspect --join guest -- sh -c '{PROBE} {LEECHCORE} 1000000=joined-in && echo gdb=$VM_INSPECT_GDB' 2>&1"))
        assert "probe ok" in out and re.search(r"gdb=/run/vm-inspect/guest\.\w{8}/gdb\.sock", out), out
        assert guest_bytes(0x1000000, 9) == b"joined-in"
        out = machine.fail(as_user("eve", 1001, "vm-inspect --join guest -- true 2>&1"))
        assert "no session open here" in out, out
        machine.succeed("pkill -u alice -f 'python3.*_inspect.py'")
        machine.wait_until_fails("ls -d /run/vm-inspect/guest.*/", timeout=20)
        machine.wait_until_fails("ls -d /run/user/1000/vm-inspect/guest", timeout=20)
        machine.fail("pgrep -u alice sleep")
        out = machine.fail(alice("vm-inspect --join guest -- true 2>&1"))
        assert "no session open here" in out, out

    with subtest("only listed domains, with shared memory, and only for an approved user"):
        out = machine.fail(alice("vm-inspect other -- true 2>&1"))
        assert "not among the domains" in out, out
        out = machine.fail(alice("vm-inspect plain -- true 2>&1"))
        assert "its memory is private to QEMU" in out, out
        machine.fail(as_user("eve", 1001, "vm-inspect guest -- true 2>&1"))
        assert machine.succeed("ls /run/user/1001/vm-inspect") == ""
        out = machine.fail("${pkgs.python3}/bin/python3 -I ${../_inspect_helper.py} ${settings} guest < /dev/null 2>&1")
        assert "started by vm-inspect, through pkexec" in out, out
  '';
}
