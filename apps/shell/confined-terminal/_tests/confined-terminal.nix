# nix build --no-link -L .#tests.confined-terminal.confined-terminal
# The confined command in a real session, where a compositor and a sound server exist to be withheld or handed over, and inside another sandbox, as an editor's terminal would start it, with a second machine to reach.
{
  host,
}:

let
  inherit (host) pkgs;

  swayConfig = pkgs.writeText "sway-config" ''
    output HEADLESS-1 resolution 1280x720
  '';

  windows = pkgs.writeShellScript "windows" ''
    ${pkgs.sway-unwrapped}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -r '.. | .app_id? | strings'
  '';
in
host.boot {
  name = "confined-terminal";
  needs = [ "apps/confine" ];

  nodes.server = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.default = {
        default = true;
        locations."/".return = "200 reached";
      };
    };
  };

  machines.machine =
    { config, lib, pkgs, ... }:
    {
      virtualisation.memorySize = 2048;
      hardware.graphics.enable = true;
      boot.kernelModules = [ "tun" ];
      networking.defaultGateway = {
        address = "192.168.1.254";
        interface = "eth1";
      };

      users.users.alice = {
        uid = 1000;
        linger = true;
      };

      my.apps.confinedTerminal = {
        enable = true;
        tint = null;
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
        pkgs.curl
        pkgs.python3
      ]
      # Sandboxes to start the command from: confine-editor without the tun device and confine-editor-with-tun with it.
      ++ lib.mapAttrsToList
        (
          name: settings:
          (config.confine.lib.wrap (
            {
              package = pkgs.runCommand "editor-env" { } "mkdir -p $out/bin";
              inherit name;
              appId = "app.test.Editor";
              home = "ephemeral";
              linger = false;
              network = "isolated";
              workdir = "rw";
              seccomp.nesting = true;
              devices = [ "/dev/net/tun" ];
            }
            // settings
          )).launcher
        )
        {
          editor.devices = [ ];
          editor-with-tun = { };
        };
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

    with subtest("started inside another sandbox, the command gets a network once that sandbox has the tun device"):
        server.wait_for_open_port(80)
        fetch = "curl -sS --max-time 10 http://server/"
        status, out = alice(f"confine-editor confined -- {fetch} 2>&1")
        assert status != 0 and "/dev/net/tun" in out, (status, out)
        status, out = alice(f"confine-editor-with-tun confined -- {fetch}")
        assert (status, out) == (0, "reached"), (status, out)

    with subtest("that network is its own, so local services of the outer sandbox stay out of reach"):
        local = "curl -s -o /dev/null --max-time 3 http://127.0.0.1:8123/"
        status, out = alice("confine-editor-with-tun sh -c " + shlex.quote(
            "python3 -m http.server 8123 --bind 127.0.0.1 >/dev/null 2>&1 & sleep 2; "
            f"{local} && echo outer-reaches; confined -- {local} || echo inner-cannot"))
        assert out.split() == ["outer-reaches", "inner-cannot"], (status, out)

    with subtest("the command keeps the name, the user and the ping setup a sandbox with a network has had"):
        # The window opened above still runs, with a pasta of its own.
        helpers = "pgrep -c -u alice '^pas(st|ta)' || true"
        before = machine.succeed(helpers)
        status, out = alice("confined -- sh -c 'cat /proc/sys/kernel/hostname; id -u; cat /proc/sys/net/ipv4/ping_group_range; curl -sS --max-time 10 http://server/'")
        # Ping is open to the group that is root's in the network's namespace, which is the user's own group here.
        assert status == 0 and out.split() == ["pasta-machine", "1000", "100", "100", "reached"], (status, out)
        assert machine.succeed(helpers) == before, "pasta outlived the command it gave a network"
  '';
}
