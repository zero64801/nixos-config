# nix build --impure --no-link -L --expr 'import ./apps/shell/_tests/confined-terminal.nix { }'
# The confined command in a real session, where a compositor and a sound server exist to be withheld or handed over.
{
  pkgs ? (builtins.getFlake (toString ../../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  swayConfig = pkgs.writeText "sway-config" ''
    output HEADLESS-1 resolution 1280x720
  '';

  windows = pkgs.writeShellScript "windows" ''
    ${pkgs.sway-unwrapped}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -r '.. | .app_id? | strings'
  '';
in
pkgs.testers.runNixOSTest {
  name = "confined-terminal";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ ../../confine/default.nix ];

      virtualisation.memorySize = 2048;
      hardware.graphics.enable = true;
      boot.kernelModules = [ "tun" ];
      networking.defaultGateway = {
        address = "192.168.1.254";
        interface = "eth1";
      };

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };

      services.pipewire = {
        enable = true;
        pulse.enable = true;
      };

      systemd.user.services.sway = {
        wantedBy = [ "default.target" ];
        environment = {
          WLR_BACKENDS = "headless";
          WLR_RENDERER = "pixman";
          WLR_LIBINPUT_NO_DEVICES = "1";
        };
        serviceConfig.ExecStart = "${pkgs.sway-unwrapped}/bin/sway --config ${swayConfig}";
      };

      environment.systemPackages = [
        pkgs.foot
        pkgs.pulseaudio
        (pkgs.callPackage ../_confined-terminal.nix { inherit (config.confine.lib) wrap; } {
          scratchDir = "Sandbox";
          tint = null;
        })
      ];
    };

  testScript = ''
    import shlex

    machine.wait_for_unit("user@1000.service")
    machine.wait_until_succeeds("ls /run/user/1000/sway-ipc.*.sock", timeout=120)
    sock = machine.succeed("ls /run/user/1000/sway-ipc.*.sock").strip()
    display = machine.succeed("ls /run/user/1000 | grep -xE 'wayland-[0-9]+'").strip()
    session = f"XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY={display} SWAYSOCK={sock}"


    def alice(command):
        return machine.execute("su alice -c " + shlex.quote(f"export {session}; cd ~/work && {command}"))


    machine.succeed("su alice -c 'mkdir -p ~/work ~/private && touch ~/private/secret'")

    with subtest("a command runs in place of the shell, with its output and exit status"):
        status, out = alice("confined -- sh -c 'echo inside; exit 7'")
        assert (status, out) == (7, "inside\n"), (status, out)
        status, out = alice("confined --")
        assert status == 2, (status, out)

    with subtest("the command sees the folder it started in and nothing else of the home"):
        status, out = alice("touch here && confined -- sh -c 'ls; ls /home/alice'")
        assert (status, out.split()) == (0, ["here", "work"]), (status, out)

    with subtest("the shell still starts without a command"):
        status, out = alice("echo 'echo shell-$((1 + 1))' | confined 2>/dev/null")
        assert status == 0 and "shell-2" in out, (status, out)

    with subtest("a window opens with --gui and has no display without it"):
        status, out = alice("confined -- sh -c 'echo ''${WAYLAND_DISPLAY:-none}; foot true'")
        assert status != 0 and out.startswith("none"), (status, out)
        alice("(confined --gui -- foot sleep 60 > foot.log 2>&1 &)")
        machine.wait_until_succeeds(f"su alice -c 'export {session}; ${windows}' | grep -qx foot", timeout=60)

    with subtest("sound is reachable with --audio alone"):
        machine.wait_until_succeeds("su alice -c " + shlex.quote(f"export {session}; pactl info"), timeout=60)
        status, out = alice("confined -- pactl info 2>&1")
        assert status != 0, (status, out)
        status, out = alice("confined --audio -- pactl info 2>&1")
        assert status == 0 and "Server Name" in out, (status, out)
  '';
}
