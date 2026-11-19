# nix build --no-link -L .#tests.lab.guest-usb
# guest-usb on what a session recorded of a USB keyboard of the test machine passed to the guest: what it told the guest of itself, its report descriptor, its control requests, and what the guest sent it between two marks to light its Caps Lock.
{
  host,
}:

host.needs [ "modules/virtualisation/inspect" ] (
  import ../../inspect/_tests/fixture.nix { inherit host; } {
    name = "guest-usb";
    usb = true;
    lab = true;

    testScript = ''
      start_driven()
      place = machine.succeed("for d in /sys/bus/usb/devices/*; do [ \"$(cat $d/product 2>/dev/null)\" = 'QEMU USB Keyboard' ] && basename $d; done; true").strip()
      machine.succeed("install -d -o alice /tmp/work/out")
      script = "; ".join([
          "guest-exec --shell 'for i in $(seq 1 100); do ls /sys/class/leds | grep -q capslock && break; sleep 0.2; done; ls /sys/class/leds'",
          "guest-mark before",
          "guest-exec --shell 'for light in /sys/class/leds/*capslock; do echo 1 > $light/brightness; done'",
          "sleep 1",
          "guest-mark after",
          "echo == devices; guest-usb devices",
          "echo == hid; guest-usb hid",
          "echo == control; guest-usb control",
          "echo == class; guest-usb control --vendor",
          "echo == urbs; guest-usb urbs --max 12",
          "echo == changes; guest-usb changes before after",
          "echo == window; guest-usb urbs --since after",
          "echo == tshark; guest-usb tshark -c 3",
      ])
      out = machine.succeed(lab(f"cd /tmp/work && vm-inspect --usb --control --plug {place} driven -- sh -c {shlex.quote('{ ' + script + '; } 2>&1')} 2>&1"))
      print(out)
      section = {}
      for part in out.split("== ")[1:]:
          name, _, said = part.partition("\n")
          section[name.strip()] = said

      with subtest("the keyboard is known by what this system's kernel and the keyboard itself said of it"):
          assert "QEMU USB Keyboard" in section["devices"] and "plugged for the session" in section["devices"], section["devices"]
          assert re.search(r"told the guest: USB \d\.\d class 0x00 id 0627:0001", section["devices"]), section["devices"]
          assert re.search(r"\d+\.\d+\s+\d+ transfers", section["devices"]), section["devices"]

      with subtest("its report descriptor reads as a keyboard with eight bytes in and one out"):
          for wanted in ["Usage Page 0x0001", "Usage 0x0006", "Collection Application", "End Collection",
                         "input report 0: 64 bits, 8 bytes", "output report 0: 8 bits, 1 bytes"]:
              assert wanted in section["hid"], f"{wanted} is missing from: {section['hid']}"

      with subtest("the control requests are listed once each, the class requests alone when asked"):
          assert "GET_DESCRIPTOR DEVICE 0" in section["control"] and "GET_DESCRIPTOR REPORT 0" in section["control"], section["control"]
          assert "SET_IDLE for HID" in section["class"] and "GET_DESCRIPTOR" not in section["class"], section["class"]

      with subtest("what the guest sent between the marks is the light's report and nothing else"):
          assert re.search(r"SET_REPORT output report 0 index 0 length 1\s+sends 02", section["changes"]), section["changes"]
          assert section["changes"].count("SET_REPORT") == 1, section["changes"]
          assert "SET_REPORT" not in section["window"], section["window"]

      with subtest("each transfer is shown with its data, and tshark runs on the capture in the box"):
          assert "GET_DESCRIPTOR DEVICE 0 index 0 length" in section["urbs"] and "18 B: 12 01" in section["urbs"], section["urbs"]
          assert len([line for line in section["tshark"].splitlines() if re.match(r"\s+\d+\s", line)]) == 3, section["tshark"]
    '';
  }
)
