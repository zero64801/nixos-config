# nix build --no-link -L .#tests.inspect.vm-inspect
# vm-inspect against a real QEMU under libvirt, running as its own user with its memory on huge pages.
{
  host,
}:

let
  inherit (host) pkgs;
  inherit (pkgs) memprocfs;

  # 5 GiB so that part of the memory lies above the hole below 4 GiB, where its place in the file and in the guest differ.
  domain =
    name: backing: extra:
    pkgs.writeText "${name}.xml" ''
      <domain type="@TYPE@" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
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
        ${extra}
      </domain>
    '';

  # No display of its own, and the memory a Looking Glass host in it would share frames through.
  shared =
    domain "guest"
      ''
        <memoryBacking><hugepages/><source type="memfd"/><allocation mode="immediate"/></memoryBacking>
      ''
      ''
        <qemu:commandline>
          <qemu:arg value="-device"/>
          <qemu:arg value="{'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}"/>
          <qemu:arg value="-object"/>
          <qemu:arg value="{'qom-type':'memory-backend-file','id':'looking-glass','mem-path':'/dev/kvmfr0','size':33554432,'share':true}"/>
        </qemu:commandline>
      '';
  private = domain "plain" "" "";

  # What a tool would send, written by hand, to see what the session and the helper make of it.
  ask = pkgs.writeText "ask.py" ''
    import socket
    import sys

    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.connect(sys.argv[1])
    conn.sendall(sys.argv[2].encode() * int(sys.argv[3]) + (b"\n" if sys.argv[3] == "1" else b""))
    print(conn.recv(65536).decode().strip())
  '';

  settings = pkgs.writeText "settings.json" (builtins.toJSON { domains = [ "guest" ]; });
in
import ./fixture.nix { inherit host; } {
  name = "vm-inspect";

  machine =
    { config, pkgs, ... }:
    {
      boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];
      boot.extraModprobeConfig = "options kvmfr static_size_mb=32";
      services.udev.extraRules = ''
        SUBSYSTEM=="kvmfr", OWNER="vm-guest", GROUP="vm-guest", MODE="0660"
      '';
      virtualisation.libvirtd.qemu.verbatimConfig = ''
        cgroup_device_acl = [ "/dev/null", "/dev/full", "/dev/zero", "/dev/random", "/dev/urandom", "/dev/ptmx", "/dev/kvm", "/dev/kvmfr0" ]
      '';

      virtualisation.memorySize = 8192;
      boot.kernelParams = [ "hugepages=2600" ];
      boot.kernelModules = [ "kvmfr" ];

      my.virtualisation.inspect.domains = [
        "guest"
        "plain"
      ];

      users.users.eve = {
        isNormalUser = true;
        uid = 1001;
        linger = true;
      };

      environment.systemPackages = [
        pkgs.gdb
        # With a second opinion on what a picture holds.
        (pkgs.python3.withPackages (p: [ p.pillow ]))
      ];
    };

  testScript = ''
    LEECHCORE = "${memprocfs}/lib/memprocfs/leechcore.so"
    PROBE = "python3 -I ${./leechcore_probe.py}"


    def guest_bytes(address, count):
        dump = machine.succeed(f"virsh qemu-monitor-command guest --hmp 'xp /{count}xb {address:#x}'")
        return bytes(int(b, 16) for b in re.findall(r"0x([0-9a-f]{2})\b", dump))


    machine.wait_for_unit("user@1001.service")
    # There before any session, so a sandbox started earlier can have been given them.
    machine.succeed("test -d /run/vm-inspect && test -d /run/user/1000/vm-inspect")
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
        out = machine.fail("${pkgs.python3.withPackages (p: [ p.libvirt ])}/bin/python3 -I ${../_inspect_helper.py} ${settings} guest < /dev/null 2>&1")
        assert "started by vm-inspect, through pkexec" in out, out

    start_driven()

    with subtest("a session gives a picture of the guest's screen, and sends input only when opened for it"):
        out = machine.succeed(session("", "guest-shot /tmp/before.png; guest-input type x; echo status=$?"))
        print(out)
        assert re.search(r"^/tmp/before\.png \d+x\d+$", out, re.MULTILINE), out
        assert "opened without --control" in out and "status=1" in out, out
        assert machine.succeed("head -c 8 /tmp/before.png | od -An -tx1").split() == "89 50 4e 47 0d 0a 1a 0a".split()
        machine.fail("grep -q typed: /var/lib/driven/serial.log")
        machine.fail(alice("command -v guest-shot"))

    with subtest("text typed from the host arrives in the guest as the same text"):
        out = machine.succeed(session("--control", "guest-input type 'Hello, World_42!' && guest-input key enter && guest-shot /tmp/after.png"
                                      " && guest-shot --crop 0 0 200 16 /tmp/part.png; guest-shot --crop 5000 0 10 10 /tmp/none.png; echo outside=$?"))
        print(out)
        # The line that was typed, where no cursor blinks, cut out of one picture and compared with the same place in another.
        assert "/tmp/part.png 200x16" in out and "lies outside the picture" in out and "outside=1" in out, out
        machine.succeed("python3 -I -c 'from PIL import Image; whole = Image.open(\"/tmp/after.png\").convert(\"RGB\").crop((0, 0, 200, 16)); "
                        "part = Image.open(\"/tmp/part.png\").convert(\"RGB\"); assert part.size == (200, 16) and len(set(part.getdata())) > 1 and part.tobytes() == whole.tobytes()'")
        # The guest's serial port ends its lines the way a terminal does.
        machine.wait_until_succeeds("tr -d '\\r' < /var/lib/driven/serial.log | grep typed: >&2; tr -d '\\r' < /var/lib/driven/serial.log | grep -qxF 'typed: Hello, World_42!'", timeout=30)
        machine.fail("cmp -s /tmp/before.png /tmp/after.png")

    with subtest("the pointer takes places, clicks, the wheel and a drag"):
        machine.succeed(session("--control", "guest-input move 0.5 0.5 && guest-input click --at 320 200 --of 640x400 --double"
                                " && guest-input scroll -2 && guest-input drag 0.1 0.1 0.9 0.9 && guest-input nudge 5 -5 && guest-input key ctrl+alt+f2"))
        out = machine.fail(session("--control", "guest-input move 700 200 --of 640x400"))
        assert "a place is two fractions" in out, out

    with subtest("the helper takes plain events alone, and a refused request leaves the session open"):
        ask = "python3 -I ${ask} $VM_INSPECT_DIR/control.sock"
        out = machine.succeed(session("--control", "; ".join([
            ask + """ '{"do":"input","events":[{"type":"key","key":"a;b","down":true}]}' 1""",
            ask + """ '{"do":"input","events":[{"type":"abs","axis":"x","value":40000}]}' 1""",
            ask + """ '{"do":"input","events":[]}' 1""",
            ask + """ '{"do":"hmp","line":"quit"}' 1""",
            ask + " not-json 1",
            ask + " x 130000",
            "guest-shot /tmp/still.png",
        ])))
        print(out)
        lines = out.splitlines()
        assert len(lines) == 7 and all('"error"' in line for line in lines[:6]), out
        assert "/tmp/still.png" in lines[6], out
        assert machine.succeed("virsh domstate driven").strip() == "running"

    with subtest("a session opened for it reaches the agent in the guest, through a channel that is there only meanwhile"):
        # The sessions before this one were opened with --control too, and each took its channel along.
        machine.wait_until_fails("virsh dumpxml driven | grep -q guest_agent", timeout=30)
        out = machine.fail(session("", "guest-agent ping"))
        assert "opened without --control" in out, out
        out = machine.succeed(session("--control", "python3 -I ${./agent_flow.py} ${pkgs.busybox}/bin/sh; guest-agent shutdown; echo status=$?"))
        print(out)
        assert "the agent ran a program and kept a file" in out, out
        assert "not among what a session may ask the agent" in out and "status=1" in out, out
        machine.succeed("tr -d '\\r' < /var/lib/driven/serial.log | grep -qxF to-the-serial")

    with subtest("the tools on top of the agent run programs, move files and search, and what they did is written down"):
        out = machine.succeed(session("--control", "; ".join([
            "guest-status",
            "guest-exec --shell 'echo said; printf \"a\\033[31mb\\n\"; exit 4'; echo status=$?",
            "echo pushed-content > /tmp/push && guest-push /tmp/push /tmp/pushed && guest-read /tmp/pushed",
            "guest-pull /tmp/pushed /tmp/pulled && cmp /tmp/push /tmp/pulled && echo same",
            "guest-pull --max 3 /tmp/pushed /tmp/never; echo pull=$?",
            "guest-ls /tmp && guest-stat /tmp/pushed && guest-hash /tmp/pushed",
            "guest-grep -F content /tmp && guest-find /tmp 'push*'",
            "guest-exec --cwd /tmp --json ls pushed",
            "guest-exec --timeout 2 sleep 30; echo slow=$?",
            "head -c 20000000 /dev/urandom > /tmp/large && guest-push /tmp/large /tmp/large && guest-pull /tmp/large /tmp/large-back && cmp /tmp/large /tmp/large-back && echo large-same",
            # Large enough to go as a disk, and no whole number of sectors.
            "head -c 150000001 /dev/urandom > /tmp/huge && guest-push /tmp/huge /tmp/huge && guest-pull /tmp/huge /tmp/huge-back && cmp /tmp/huge /tmp/huge-back && echo huge-same",
            "guest-push --disk /tmp/push /tmp/small-by-disk && guest-read /tmp/small-by-disk",
        ])))
        print(out)
        for wanted in ["agent: ", "said", "a[31mb", "status=4", "pushed-content", "same", "more than the 3 allowed", "pull=1", "/tmp/pushed:1:pushed-content",
                       '"exit": 0', "still running after 2 seconds", "slow=1", "large-same", "huge-same",
                       "150000001 bytes are in the guest as /tmp/huge, checked. By disk", "are in /tmp/huge-back, checked. By disk",
                       "are in the guest as /tmp/small-by-disk, checked. By disk"]:
            assert wanted in out, f"{wanted} is missing from: {out}"
        assert "\x1b" not in out, "what the guest printed can still steer a terminal"
        written = machine.succeed("cat /home/alice/.local/state/vm-inspect/driven.log")
        print(written)
        assert "guest-exec /bin/sh -c echo said" in written and "guest-file-open /tmp/pushed w -> done" in written, written
        assert "guest-shutdown -> refused" in written and "guest-file-write" not in written, written
        assert "a file plugged into the guest as a disk it may read -> done" in written and "as a disk it may write -> done" in written, written
        machine.fail("virsh dumpxml driven | grep -q vm-inspect-data")
        machine.wait_until_fails("virsh dumpxml driven | grep -q guest_agent", timeout=30)
        machine.succeed(alice("vm-inspect --control driven -- sleep 30 >/dev/null 2>&1 &"))
        machine.wait_until_succeeds("virsh dumpxml driven | grep -q ua-vm-inspect-agent", timeout=30)
        machine.succeed("pkill -u alice -f 'python3.*_inspect.py'")
        machine.wait_until_fails("virsh dumpxml driven | grep -q guest_agent", timeout=30)
        machine.wait_until_fails("ls -d /run/user/1000/vm-inspect/driven", timeout=20)
        # A guest with nothing to plug the channel into is still opened, and says why its agent is out of reach.
        out = machine.fail(lab("vm-inspect --control guest -- guest-agent ping 2>&1"))
        assert "could not be plugged into the guest" in out, out

    with subtest("a program runs as another account or is left to run as a job, and a script runs with the interpreter the guest has"):
        machine.succeed("printf 'echo \"script got $1 as $(id -un)\"\nexit 7\n' > /tmp/script",
                        "printf 'echo \"sleeping as $(id -un)\"\nsleep 300\n' > /tmp/sleeper")
        out = machine.succeed(session("--control", "; ".join([
            "guest-exec --user tester id -un",
            "guest-exec --user tester --cwd /tmp --shell 'pwd; echo home=$HOME'",
            "guest-exec --as-user true; echo nobody=$?",
            "guest-exec --elevated true; echo elevated=$?",
            "guest-py /tmp/script; echo nopython=$?",
            "guest-py --python /bin/sh /tmp/script one; echo py=$?",
            "guest-py --python /bin/sh --user tester /tmp/script two; echo user=$?",
            "guest-exec mv /bin/stands-in-for-python /bin/python3 && guest-py /tmp/script found; echo found=$?",
            "guest-find /tmp 'vm-inspect-*'",
            "job=$(guest-exec --job --shell 'echo begun; sleep 2; echo ended; exit 3' | cut -d' ' -f2)",
            "guest-job status $job",
            "guest-wait --file /run/vm-inspect-jobs/$job.exit --timeout 20",
            "guest-job status $job; guest-job log $job",
            "long=$(guest-py --python /bin/sh --job --user tester /tmp/sleeper | cut -d' ' -f2)",
            "guest-wait --process sleep --timeout 20; guest-job log $long",
            "guest-job stop $long; guest-wait --process sleep --gone --timeout 20; echo gone=$?",
            "guest-job status | sed 's/^[0-9a-f]* /listed/'",
            # A job that writes down an end of its own while it is being stopped, as one does whose shell outlives its program by a moment.
            "raced=$(guest-exec --job --shell 'f=$(grep -lx $$ /run/vm-inspect-jobs/*.pid); trap \"echo 143 > ''${f%.pid}.exit; exit 143\" TERM; sleep 300 & wait' | cut -d' ' -f2)",
            "guest-wait --process sleep --timeout 20 > /dev/null; guest-job stop $raced > /dev/null; guest-job status $raced | sed 's/^[0-9a-f]* /raced/'",
            "guest-wait --process no-such --timeout 1; echo waited=$?",
            "guest-job clean > /dev/null; guest-job status; echo cleared",
            "guest-windows; echo windows=$?",
        ])))
        print(out)
        for wanted in ["tester\n", "/tmp\nhome=/tmp", "nobody is logged in", "nobody=1", "--elevated goes with", "elevated=1", "no Python was found", "nopython=1",
                       "script got one as root", "py=7", "script got two as tester", "user=7", "script got found as root", "found=7",
                       "  running", "  exit 3", "begun\nended", "sleeping as tester", "sleep is gone", "gone=0", "listed exit 3", "listed stopped", "raced stopped",
                       "was still missing after 1 seconds", "waited=1", "only a Windows guest", "windows=1"]:
            assert wanted in out, f"{wanted} is missing from: {out}"
        assert "/tmp/vm-inspect-" not in out, "a script was left in the guest"
        assert re.search(r"what follows was written by the guest\ncleared", out), "the finished jobs were not cleared away"

    with subtest("a program given a number the guest used before gets its own answer, not one an earlier program left with the agent"):
        out = machine.succeed(session("--control", "; ".join([
            "guest-exec --shell 'echo 400 > /proc/sys/kernel/pid_max' 2>/dev/null",
            "for i in 1 2 3; do guest-exec --job --shell 'sleep 1' > /dev/null; done",
            "guest-exec --timeout 1 sleep 30 > /dev/null 2>&1",
            "sleep 2",
            "for i in $(seq 1 300); do said=$(guest-exec --shell \"echo n$i\" 2>/dev/null); [ \"$said\" = n$i ] || echo \"wrong $i: $said\"; done; echo checked",
        ])))
        print(out)
        assert "checked" in out and "wrong" not in out, out

    with subtest("a guest that answers as badly as it can leads no tool astray"):
        out = machine.succeed(lab("python3 -I ${./hostile_agent.py} 2>&1"))
        print(out)
        assert "no tool was led astray" in out, out

    with subtest("a transfer's disk is one plain file, a guest that is to read it cannot write it, and the session takes it along"):
        out = machine.succeed(session("--control", "python3 -I ${./disk_flow.py}"))
        print(out)
        assert "could only be read" in out, out
        machine.wait_until_fails("virsh dumpxml driven | grep -q vm-inspect-data", timeout=30)
        machine.succeed("grep -q 'kept as it was' /tmp/kept")

    with subtest("a guest QEMU draws no screen for gives the newest frame Looking Glass shares"):
        fake = "python3 -I ${./fake_looking_glass.py}"
        out = machine.fail(lab("vm-inspect guest -- guest-shot --source qemu /tmp/none.png 2>&1"))
        assert "QEMU draws no screen for this guest" in out, out
        out = machine.fail(lab("vm-inspect guest -- guest-shot /tmp/none.png 2>&1"))
        assert "nothing in the guest has set Looking Glass up" in out, out
        machine.succeed(f"systemd-run --unit=looking-glass {fake} /dev/kvmfr0 70 50 watched 33554432")
        machine.wait_until_succeeds("systemctl is-active looking-glass")
        out = machine.succeed(lab("vm-inspect guest -- guest-shot /tmp/frame.png 2>&1"))
        assert "/tmp/frame.png 70x50" in out, out
        print(machine.succeed(f"{fake} check /tmp/frame.png 70 50"))
        machine.succeed("systemctl stop looking-glass")
        # The way its display driver sends a desktop: 24 bit pixels packed into rows of a narrower 32 bit surface.
        machine.succeed(f"systemd-run --unit=looking-glass {fake} /dev/kvmfr0 70 50 watched 33554432 5")
        out = machine.succeed(lab("vm-inspect guest -- guest-shot /tmp/packed.png 2>&1"))
        assert "/tmp/packed.png 70x50" in out, out
        print(machine.succeed(f"{fake} check /tmp/packed.png 70 50"))
        machine.succeed("systemctl stop looking-glass")
        # HDR, as ten bits in its own curve and wide colours, and as floats.
        # Ten bit steps of two bright colours show as up to 15 levels in a third that is nearly absent, which is in what is sent and not in how it is read.
        for name, kind, slack in [("hdr", "3 hdr", 16), ("floats", "4", 0)]:
            machine.succeed(f"systemd-run --unit=looking-glass {fake} /dev/kvmfr0 256 256 watched 33554432 {kind}")
            out = machine.succeed(lab(f"vm-inspect guest -- guest-shot /tmp/{name}.png 2>&1"))
            assert f"/tmp/{name}.png 256x256" in out, out
            print(machine.succeed(f"{fake} check /tmp/{name}.png 256 256 {slack}"))
            machine.succeed("systemctl stop looking-glass")
        out = machine.fail(lab("vm-inspect guest -- guest-shot /tmp/none.png 2>&1"))
        assert "host program in the guest has stopped" in out, out
        machine.succeed(f"systemd-run --unit=looking-glass {fake} /dev/kvmfr0 70 50 unwatched 33554432")
        out = machine.fail(lab("vm-inspect guest -- guest-shot /tmp/none.png 2>&1"))
        assert "only while its client shows it" in out, out
        machine.succeed("systemctl stop looking-glass")
        out = machine.fail(session("", "guest-shot --source frames /tmp/none.png"))
        assert "shares no frames through Looking Glass" in out, out

    with subtest("no other user reaches the session's control socket"):
        machine.succeed(alice("vm-inspect --control driven -- sleep 30 >/dev/null 2>&1 &"))
        machine.wait_until_succeeds("test -S /run/user/1000/vm-inspect/driven/control.sock", timeout=20)
        machine.fail("su eve -c 'python3 -I ${ask} /run/user/1000/vm-inspect/driven/control.sock {} 1'")
        out = machine.succeed(lab("vm-inspect --join driven -- guest-shot /tmp/joined.png"))
        assert "/tmp/joined.png" in out, out
  '';
}
