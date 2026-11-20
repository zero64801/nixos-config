# nix build --no-link -L .#tests.inspect.capture
# A session that records its guest: the network from the tap on this side, with vhost as real guests have it, and a USB keyboard of this machine passed to the guest for the session, with a tablet on the same bus that must not show.
{
  host,
}:

let
  inherit (host) pkgs;
  tshark = "${pkgs.wireshark-cli}/bin/tshark";
in
import ./fixture.nix { inherit host; } {
  name = "capture";
  network = true;
  usb = true;

  machine = {
    my.virtualisation.inspect.capture.limit = 48 * 1024 * 1024;
    my.virtualisation.inspect.capture.keep = false;
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
      pkgs.usbutils
    ];
  };

  testScript = { nodes, ... }: ''
    import json


    # vm-inspect's own words come with the command's, which the session helper above leaves out. This machine deletes a
    # capture with its session, so the sessions whose capture is looked at afterwards keep theirs.
    def recorded(options, script, keep="--keep"):
        return machine.succeed(lab(f"vm-inspect {keep} {options} driven -- sh -c {shlex.quote('{ ' + script + '; } 2>&1')} 2>&1"))


    def capture_of(out):
        found = re.search(r"recording into (\S+)", out)
        assert found, f"the session said nothing of a capture: {out}"
        return found.group(1)


    def fields(path, *names, display=""):
        found = machine.succeed(f"${tshark} -r {path} {('-Y ' + shlex.quote(display)) if display else ""} -T fields "
                                + " ".join(f"-e {name}" for name in names))
        return [line.split("\t") for line in found.splitlines() if line.strip()]


    def described(folder):
        return json.loads(machine.succeed(f"cat {folder}/capture.json"))


    machine.succeed(
        "install -d /srv/site && echo 'hello from the site' > /srv/site/hello.txt",
        "head -c 16M /dev/urandom > /srv/site/sixteen && head -c 64M /dev/urandom > /srv/site/sixty-four",
        "systemd-run --unit=site python3 -m http.server 8000 --bind 10.9.9.1 --directory /srv/site",
    )
    machine.wait_until_succeeds("curl -sf http://10.9.9.1:8000/hello.txt", timeout=30)
    start_driven()
    devices_before = machine.succeed("virsh dumpxml driven | grep -cE '<(interface|hostdev) '")

    with subtest("what the guest sends and gets is recorded on the tap, with vhost moving the frames, and the guest gets no device for it"):
        out = recorded("--net --control", "echo capture=$VM_INSPECT_CAPTURE; guest-mark before; "
                       "guest-exec --shell 'nslookup site.test 10.9.9.1; wget -q -O - http://site.test:8000/hello.txt'; guest-mark after")
        print(out)
        folder = capture_of(out)
        assert f"capture={folder}" in out and "hello from the site" in out and "marked before" in out, out
        assert int(machine.succeed("ls -l /proc/$(cat /run/libvirt/qemu/driven.pid)/fd | grep -c vhost-net")) > 0
        assert machine.succeed("virsh dumpxml driven | grep -cE '<(interface|hostdev) '") == devices_before
        assert machine.succeed(f"stat -c %a {folder} {folder}/net.pcapng {folder}/capture.json").split() == ["700", "600", "600"]
        requests = fields(f"{folder}/net.pcapng", "frame.packet_flags_direction", "http.request.uri", "frame.time_epoch", display="http.request")
        responses = fields(f"{folder}/net.pcapng", "frame.packet_flags_direction", "http.response.code", display="http.response")
        assert [r[:2] for r in requests] == [["0x00000002", "/hello.txt"]], requests
        assert [r[:2] for r in responses] == [["0x00000001", "200"]], responses
        answers = fields(f"{folder}/net.pcapng", "dns.qry.name", "dns.a", display="dns.flags.response == 1")
        assert ["site.test", "10.9.9.1"] in answers, answers
        marks = [json.loads(line) for line in machine.succeed(f"cat {folder}/notes.jsonl").splitlines()]
        assert [m["mark"] for m in marks] == ["before", "after"], marks
        assert marks[0]["time"] / 1e9 < float(requests[0][2]) < marks[1]["time"] / 1e9, (marks, requests)
        said = described(folder)
        assert [t["name"] for t in said["net"]] == ["vm-driven"] and said["stopped"] is None and said["ended"], said
        assert said["frames"] > 0 and said["frames_dropped"] == 0 and said["usb"] is None, said

    with subtest("a large download is recorded whole, at the speed the guest takes it"):
        out = recorded("--net --control", "guest-exec --timeout 120 --shell 'wget -q -O /dev/null http://site.test:8000/sixteen && echo fetched'")
        folder = capture_of(out)
        said = described(folder)
        print(said)
        assert "fetched" in out and said["frames_dropped"] == 0 and said["bytes"] > 16 * 1024 * 1024, said
        carried = fields(f"{folder}/net.pcapng", "tcp.len", display="tcp.srcport == 8000")
        assert sum(int(c[0]) for c in carried) >= 16 * 1024 * 1024, "the download's bytes are not all in the capture"

    with subtest("a session stops recording at its limit, says so, and the guest goes on"):
        out = recorded("--net --control", "guest-exec --timeout 120 --shell 'wget -q -O /dev/null http://site.test:8000/sixty-four && echo fetched'")
        folder = capture_of(out)
        said = described(folder)
        assert "the capture stopped, the limit of 50331648 bytes was reached" in out and "fetched" in out, out
        assert said["stopped"] == "the limit of 50331648 bytes was reached" and said["bytes"] <= 48 * 1024 * 1024, said

    with subtest("as capture.keep says, a capture is deleted with its session unless that is opened with --keep, and says so"):
        out = recorded("--net --control", "guest-exec --shell 'wget -q -O - http://site.test:8000/hello.txt'; ls $VM_INSPECT_CAPTURE", keep="")
        folder = capture_of(out)
        assert "hello from the site" in out and "net.pcapng" in out and "deleted when the session ends unless" in out, out
        assert "deleted with the session as capture.keep says" in out, out
        machine.fail(f"test -e {folder}")
        assert machine.succeed(f"ls {folder.rsplit('/', 1)[0]}").split(), "the kept captures went too"

    with subtest("a program that joins the session records into the same capture, and a session that records nothing says so"):
        machine.succeed(lab("vm-inspect --keep --net driven -- sleep 20 > /tmp/held.log 2>&1 &"))
        machine.wait_until_succeeds("grep -q 'recording into' /tmp/held.log", timeout=30)
        folder = capture_of(machine.succeed("cat /tmp/held.log"))
        out = machine.succeed(lab("vm-inspect --join driven -- sh -c 'echo $VM_INSPECT_CAPTURE; guest-mark joined'"))
        assert folder in out and "marked joined" in out, out
        machine.wait_until_fails("pgrep -u alice -f '_inspect.py.* --net driven'", timeout=60)
        assert '"mark": "joined"' in machine.succeed(f"cat {folder}/notes.jsonl")
        out = recorded("--control", "guest-mark nowhere; echo status=$?")
        assert "this session records nothing" in out and "status=1" in out, out

    with subtest("what a tool adds to a capture is checked: keys are lines of a key log, owners plain fields"):
        note = ("python3 -I -B -c 'import json, sys; sys.path.insert(0, \"${nodes.machine.my.virtualisation.inspect.guestLibrary}\"); "
                "from session import ask, control_socket, Refused\n"
                "try:\n    print(ask(control_socket(), json.loads(sys.argv[1]))[0])\nexcept Refused as e:\n    print(\"refused:\", e)' ")
        good_key = "CLIENT_RANDOM " + "ab" * 32 + " " + "cd" * 48
        good_update = "SERVER_TRAFFIC_SECRET_2 " + "ab" * 32 + " " + "ef" * 32
        out = recorded("--net", "; ".join([
            note + shlex.quote(json.dumps({"do": "note", "kind": "keys", "lines": [good_key]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "keys", "lines": ["rm -rf / " + "ab" * 32]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "owners", "entries": [{"proto": "tcp", "pid": 7, "process": "ok"}]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "owners", "entries": [{"process": "\x1b[2Jbad"}]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "owners", "entries": [{"command": "x"}]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "processes", "entries": [{"pid": 9, "ppid": 7, "process": "child"}]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "processes", "entries": [{"pid": 9, "ppid": -1, "process": "child"}]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "processes", "entries": [{"pid": 9, "proto": "tcp"}]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "updated", "lines": [good_update]})),
            note + shlex.quote(json.dumps({"do": "note", "kind": "updated", "lines": [good_key]})),
        ]))
        print(out)
        folder = capture_of(out)
        assert out.count("refused:") == 6 and out.count("'folder':") == 4, out
        assert machine.succeed(f"cat {folder}/updated.log").strip() == good_update
        assert machine.succeed(f"cat {folder}/keys.log").strip() == good_key
        assert '"process": "ok"' in machine.succeed(f"cat {folder}/owners.jsonl")
        assert '"ppid": 7, "process": "child"' in machine.succeed(f"cat {folder}/processes.jsonl")

    with subtest("a USB device of this machine is passed to the guest for the session and recorded, and only it, though the bus has more"):
        place = machine.succeed("for d in /sys/bus/usb/devices/*; do [ \"$(cat $d/product 2>/dev/null)\" = 'QEMU USB Keyboard' ] && basename $d; done; true").strip()
        bus, keyboard = (int(machine.succeed(f"cat /sys/bus/usb/devices/{place}/{n}")) for n in ("busnum", "devnum"))
        tablet = int(machine.succeed(f"for d in /sys/bus/usb/devices/{bus}-*; do [ \"$(cat $d/product 2>/dev/null)\" = 'QEMU USB Tablet' ] && cat $d/devnum; done; true"))
        machine.succeed(lab(f"vm-inspect --keep --usb --plug {place} driven -- sleep 25 > /tmp/usb.log 2>&1 &"))
        machine.wait_until_succeeds("virsh dumpxml driven | grep -q ua-vm-inspect-usb-0", timeout=30)
        machine.wait_until_succeeds(f"test -e /dev/usbmon{bus}", timeout=30)
        # Everything on the bus, read as root, to show that this side did use the tablet meanwhile.
        machine.succeed(f"systemd-run --unit=all-usb ${tshark} -i usbmon{bus} -w /tmp/all-usb.pcapng")
        machine.sleep(3)
        machine.succeed(f"lsusb -v -s {bus}:{tablet} > /dev/null 2>&1 || true")
        machine.sleep(3)
        machine.succeed("systemctl stop all-usb")
        machine.wait_until_fails("pgrep -u alice -f '_inspect.py.* --usb'", timeout=90)
        print(machine.succeed("cat /tmp/usb.log"))
        folder = capture_of(machine.succeed("cat /tmp/usb.log"))
        mine = fields(f"{folder}/usb.pcapng", "usb.bus_id", "usb.device_address", "usb.setup.bRequest")
        everything = fields("/tmp/all-usb.pcapng", "usb.device_address")
        assert mine and {(int(m[0]), int(m[1])) for m in mine} == {(bus, keyboard)}, mine
        assert any(m[2] == "6" for m in mine), "no GET_DESCRIPTOR of the keyboard was recorded"
        assert [str(tablet)] in everything, "this side did not use the tablet, so the test shows nothing"
        said = described(folder)
        assert [d["product"] for d in said["plugged"]] == ["QEMU USB Keyboard"] and said["usb"] and said["usb_records"] == len(mine), said
        machine.fail("virsh dumpxml driven | grep -q ua-vm-inspect-usb")
        assert machine.succeed("virsh dumpxml driven | grep -cE '<(interface|hostdev) '") == devices_before
  '';
}
