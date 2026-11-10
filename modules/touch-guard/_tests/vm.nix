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
    from dbus_fast.service import ServiceInterface, method


    class Notifications(ServiceInterface):
        def __init__(self):
            super().__init__("org.freedesktop.Notifications")
            self.count = 0

        @method()
        def Notify(self, app: "s", replaces: "u", icon: "s", summary: "s", body: "s", actions: "as", hints: "a{sv}", timeout: "i") -> "u":
            self.count += 1
            with open("/tmp/notifications.jsonl", "a") as f:
                f.write(json.dumps({"summary": summary, "body": body}) + "\n")
            return self.count

        @method()
        def CloseNotification(self, notification: "u"):
            pass

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
