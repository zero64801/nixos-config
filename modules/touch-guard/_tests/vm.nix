# nix build --impure --no-link -L --expr 'import ./modules/touch-guard/_tests/vm.nix { }'
{
  pkgs ? (builtins.getFlake (toString ../../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  notifications = pkgs.writers.writePython3 "fake-notifications" {
    libraries = [ pkgs.python3Packages.dbus-fast ];
    flakeIgnore = [ "E501" "F821" "F722" ];
  } ''
    import asyncio
    import json

    from dbus_fast.aio import MessageBus
    from dbus_fast.service import ServiceInterface, method, signal


    class Notifications(ServiceInterface):
        def __init__(self):
            super().__init__("org.freedesktop.Notifications")
            self.count = 0
            self.bodies = {}

        @method()
        def Notify(self, app: "s", replaces: "u", icon: "s", summary: "s", body: "s", actions: "as", hints: "a{sv}", timeout: "i") -> "u":
            self.count += 1
            self.bodies[self.count] = body
            with open("/tmp/notifications.jsonl", "a") as f:
                f.write(json.dumps({"id": self.count, "summary": summary, "body": body}) + "\n")
            return self.count

        @method()
        def CloseNotification(self, notification: "u"):
            with open("/tmp/notifications-closed", "a") as f:
                f.write(f"{notification}\n")
            self.NotificationClosed(notification, 3)

        @signal()
        def NotificationClosed(self, notification: "u", reason: "u") -> "uu":
            return [notification, reason]

        @method()
        def Dismiss(self, text: "s"):
            self.NotificationClosed(max(n for n, body in self.bodies.items() if text in body), 2)

        @method()
        def GetCapabilities(self) -> "as":
            return ["body", "body-markup"]

        @method()
        def GetServerInformation(self) -> "ssss":
            return ["fake", "touch-guard test", "1", "1.2"]


    async def main():
        bus = await MessageBus().connect()
        bus.export("/org/freedesktop/Notifications", Notifications())
        await bus.request_name("org.freedesktop.Notifications")
        await asyncio.get_running_loop().create_future()


    asyncio.run(main())
  '';
in
pkgs.testers.runNixOSTest {
  name = "touch-guard";

  nodes.machine = {
    imports = [
      ../../../core/options.nix
      ../../../core/sudo.nix
      ../../../core/polkit.nix
      ../default.nix
    ];

    my.security.touchGuard = {
      enable = true;
      user = "alice";
    };

    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      password = "pw";
      linger = true;
    };

    specialisation.other.configuration = {
      users.users.eve = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      security.sudo.extraConfig = "Defaults lecture=never";
    };

    systemd.user.services.fake-notifications = {
      wantedBy = [ "default.target" ];
      serviceConfig.ExecStart = notifications;
    };

    security.polkit.enable = true;
    environment.systemPackages = [ pkgs.python3 ];

    # A stand-in key: uhid gives it a real hidraw node, which is what the daemon's kernel probes follow.
    boot.kernelModules = [ "uhid" ];
    environment.etc."touch-guard-test/fake_key.py".source = ./fake_key.py;
    environment.etc."touch-guard-test/use_key.py".source = ./use_key.py;
  };

  testScript = ''
    import shlex


    def as_alice(command):
        return "su - alice -c " + shlex.quote(command)


    def sudo(command):
        return as_alice("echo pw | sudo -S --prompt= " + command + " 2>&1")


    def notified(text):
        machine.wait_until_succeeds("grep -F " + shlex.quote(text) + " /tmp/notifications.jsonl", timeout=20)


    machine.wait_for_unit("touch-guard.service")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("fake-notifications.service", "alice")
    machine.succeed("systemctl --user -M alice@ start touch-guard-notify.service")

    with subtest("a request shown on screen goes ahead"):
        machine.wait_until_succeeds(sudo("true"), timeout=30)
        notified("sudo (runs as root)")

    with subtest("sudo takes no variables, no caller PATH and keeps no approval"):
        assert "not allowed to preserve the environment" in machine.fail(sudo("-E true"))
        assert "not allowed to set" in machine.fail(sudo("FOO=1 true"))
        machine.succeed(as_alice("mkdir -p ~/bin && printf '#!/bin/sh\\necho planted\\n' > ~/bin/id && chmod +x ~/bin/id"))
        assert machine.succeed(as_alice("PATH=$HOME/bin:$PATH; echo pw | sudo -S --prompt= id -u")).strip() == "0"
        machine.fail(as_alice("echo pw | sudo -S --prompt= true && sudo -n true"))

    with subtest("the rebuild diff is on screen before the approval"):
        spec = machine.succeed("readlink -f /run/current-system/specialisation/other").strip()
        machine.execute(sudo(spec + "/bin/switch-to-configuration dry-activate"))
        notified("changes accounts: wheel +eve")
        notified("changes root access config: sudoers")
        notified("accounts: new user eve")

    with subtest("run0 requests show the command systemd was asked to run"):
        machine.wait_until_tty_matches("1", "login: ")
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("1", "Password: ")
        machine.send_chars("pw\n")
        machine.sleep(2)
        machine.send_chars("run0 /run/current-system/sw/bin/touch /tmp/run0-ok\n")
        machine.wait_until_tty_matches("1", "AUTHENTICATING FOR")
        machine.wait_until_tty_matches("1", "touch-guard: run0 \\(runs as root\\)")
        machine.sleep(1)
        machine.send_chars("pw\n")
        machine.wait_for_file("/tmp/run0-ok")
        notified("run0 (runs as root)")
        notified("/run/current-system/sw/bin/touch /tmp/run0-ok")

    def use_key(name, mode, seconds, key_waits=0):
        machine.succeed(f"cp /etc/touch-guard-test/use_key.py /tmp/{name}.py")
        machine.succeed(f"python3 -I /tmp/{name}.py {mode} {seconds} {key_waits} >/dev/null 2>&1 &")


    with subtest("of two programs with the key open, only the one that sent to it is named"):
        machine.succeed("python3 -I /etc/touch-guard-test/fake_key.py 3 >/tmp/fake-key.log 2>&1 &")
        machine.wait_until_succeeds("journalctl -u touch-guard | grep -q 'following which programs send to a security key'", timeout=30)
        use_key("idle-holder", "idle", 120)
        machine.sleep(1)
        use_key("asker", "write", 5)
        notified("asker.py")
        machine.wait_until_succeeds("journalctl -u touch-guard | grep 'without sending to it, left out' | grep -q python")
        machine.fail("grep -F idle-holder.py /tmp/notifications.jsonl")

    with subtest("a report sent through an ioctl counts as sending"):
        machine.sleep(5)
        use_key("ioctl-asker", "ioctl", 5)
        notified("ioctl-asker.py")
        machine.fail("grep -F idle-holder.py /tmp/notifications.jsonl")

    with subtest("a program that sends while the key already waits is called out"):
        machine.sleep(5)
        use_key("first-asker", "write", 5)
        notified("first-asker.py")
        use_key("late-sender", "write", 5)
        notified("late-sender.py")
        notified("sent to the key while it was already waiting")
        machine.fail("grep -F idle-holder.py /tmp/notifications.jsonl")

    with subtest("closing the notification makes the key drop its wait, a close nobody made does not"):
        machine.sleep(5)
        bus = "busctl --address=unix:path=/run/user/1000/bus"
        server = "org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications"
        called_out = machine.succeed("grep -c 'already waiting' /tmp/notifications.jsonl").strip()
        use_key("cancelled-asker", "write", 40, 30)
        notified("cancelled-asker.py")
        shown = machine.succeed("grep -F cancelled-asker.py /tmp/notifications.jsonl | tail -n 1")
        number = shown.split('"id": ')[1].split(",")[0]
        machine.succeed(as_alice(f"{bus} emit /org/freedesktop/Notifications org.freedesktop.Notifications NotificationClosed uu {number} 2"))
        machine.sleep(3)
        machine.fail("journalctl -u touch-guard | grep -q 'cancelled from the notification'")
        machine.succeed(as_alice(f"{bus} call {server} Dismiss s cancelled-asker.py"))
        machine.wait_until_succeeds("journalctl -u touch-guard | grep -q 'ended: cancelled'", timeout=10)
        machine.wait_until_succeeds(f"grep -qx {number} /tmp/notifications-closed", timeout=10)
        machine.sleep(3)
        assert machine.succeed("grep -c 'already waiting' /tmp/notifications.jsonl").strip() == called_out, "the daemon's own cancel was taken for a request"

    def wakeups():
        """How often the daemon's threads went to sleep and were woken again, since it started."""
        return int(machine.succeed(
            "pid=$(systemctl show -p MainPID --value touch-guard) && "
            "cat /proc/$pid/task/*/status | awk '/^voluntary_ctxt_switches/ { n += $2 } END { print n }'"))


    with subtest("with nothing asking, the daemon sleeps"):
        machine.sleep(5)
        before = wakeups()
        machine.sleep(10)
        woken = wakeups() - before
        print(f"the idle daemon woke {woken} times in 10 seconds")
        assert woken <= 5, f"the idle daemon woke {woken} times in 10 seconds"

    with subtest("a key plugged in while the daemon sleeps is watched at once"):
        machine.succeed("python3 -I /etc/touch-guard-test/fake_key.py 4 >/tmp/fake-key-2.log 2>&1 &")
        machine.wait_until_succeeds("test $(journalctl -u touch-guard | grep -c 'watching /dev/hidraw') -ge 2", timeout=5)
        machine.fail("journalctl -u touch-guard | grep -q 'no hotplug event'")

    with subtest("refused while no notifier runs"):
        machine.succeed("systemctl --user -M alice@ stop touch-guard-notify.service")
        assert "no notifier is running" in machine.fail(sudo("true"))

    with subtest("a program posing as the notifier is refused"):
        machine.succeed(as_alice(
            "nohup python3 -c 'import socket, time; s = socket.socket(socket.AF_UNIX); "
            "s.connect(\"/run/touch-guard/events.sock\"); time.sleep(600)' >/dev/null 2>&1 &"))
        machine.wait_until_succeeds("journalctl -u touch-guard | grep -q 'refused a notifier'")
        assert "no notifier is running" in machine.fail(sudo("true"))

    with subtest("a notifier with a preloaded library is refused"):
        machine.succeed(as_alice(
            "mkdir -p ~/.config/systemd/user/touch-guard-notify.service.d && "
            "printf '[Service]\\nEnvironment=LD_PRELOAD=/nonexistent.so\\n' > ~/.config/systemd/user/touch-guard-notify.service.d/x.conf"))
        machine.succeed("systemctl --user -M alice@ daemon-reload")
        machine.succeed("systemctl --user -M alice@ start touch-guard-notify.service")
        machine.wait_until_succeeds("journalctl -u touch-guard | grep -q 'its environment sets LD_PRELOAD'")
        assert "no notifier is running" in machine.fail(sudo("true"))
        machine.succeed("rm -r /home/alice/.config/systemd/user/touch-guard-notify.service.d")
        machine.succeed("systemctl --user -M alice@ daemon-reload")
        machine.succeed("systemctl --user -M alice@ restart touch-guard-notify.service")
        machine.wait_until_succeeds(sudo("true"), timeout=30)

    with subtest("a text console still works with touch-guard stopped"):
        machine.succeed("systemctl stop touch-guard.service")
        assert "touch-guard is not running" in machine.fail(sudo("true"))
        machine.send_chars("sudo touch /tmp/console-ok\n")
        machine.wait_until_tty_matches("1", "password for alice")
        machine.send_chars("pw\n")
        machine.wait_for_file("/tmp/console-ok")
  '';
}
