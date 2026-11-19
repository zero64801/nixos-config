# nix build --no-link -L .#tests.studio-broker.studio-broker
{
  host,
}:

let
  inherit (host) pkgs;

  idle = 3;

  flatpak = pkgs.writeShellScriptBin "flatpak" ''
    shift 6
    exec -a 'C:\Program Files\Roblox\RobloxStudioBeta.exe' ${pkgs.runtimeShell} -c \
      'while :; do ${pkgs.coreutils}/bin/sleep 0.2; done' studio "$@"
  '';

  displayNumber = "7";
  display = ":${displayNumber}";

  xserver = pkgs.writeShellScript "xserver" ''
    ${pkgs.xauth}/bin/xauth -f "$XDG_RUNTIME_DIR/xauth" add ${display} . "$(${pkgs.util-linux}/bin/mcookie)"
    exec ${pkgs.xvfb}/bin/Xvfb ${display} -screen 0 1280x720x24 -auth "$XDG_RUNTIME_DIR/xauth"
  '';
in
host.boot {
  name = "studio-broker";

  machines.machine = {
    imports = [ ../studio-broker.nix ];

    my.apps.studioBroker = {
      enable = true;
      lockFolders = [ "downloads" ];
      idleTimeout = idle;
    };

    users.users.alice.linger = true;

    systemd.user.services.xserver = {
      wantedBy = [ "default.target" ];
      serviceConfig.ExecStart = xserver;
    };

    environment.systemPackages = [
      flatpak
      (pkgs.python3.withPackages (ps: [ ps.xlib ]))
    ];
    environment.etc."studio-broker-test/ask.py".source = ./studio_ask.py;
    environment.etc."studio-broker-test/window.py".source = ./studio_window.py;
  };

  testScript = ''
    import json
    import shlex

    SOCKET = "/run/user/1000/studio-broker/socket"
    PLACES = "/home/alice/.var/app/org.vinegarhq.Vinegar/data/lumen-places"
    ACTIVE = "systemctl --user -M alice@ is-active studio-broker.service"
    X11 = "DISPLAY=${display} XAUTHORITY=/run/user/1000/xauth"


    def as_alice(command):
        return "su - alice -c " + shlex.quote(command)


    def ask(request):
        command = f"python3 /etc/studio-broker-test/ask.py {SOCKET} {shlex.quote(json.dumps(request))}"
        return json.loads(machine.succeed(as_alice(command)).splitlines()[0])


    def grab(window, width=320, height=240):
        """The reply to a grab, and the colours of the pixels it sent."""
        request = {"op": "grab", "window": window, "x": 0, "y": 0, "width": width, "height": height}
        command = f"python3 /etc/studio-broker-test/ask.py {SOCKET} {shlex.quote(json.dumps(request))}"
        header, *pixels = [json.loads(line) for line in machine.succeed(as_alice(command)).splitlines()]
        if not pixels:
            return header, set()
        assert pixels[0]["bytes"] == width * height * 4, pixels
        layout = header["layout"]
        return header, {"".join(pixel[2 * layout[c]:2 * layout[c] + 2] for c in "rgb") for pixel in pixels[0]["pixels"]}


    def show_window(name, title, wm_class, pid, colour):
        """Opens a window above the ones already there and returns its id and the pid of the program holding it."""
        machine.succeed(as_alice(
            f"{X11} nohup python3 /etc/studio-broker-test/window.py {shlex.quote(title)} {wm_class} {pid} {colour} "
            f"/tmp/{name}.window >/dev/null 2>&1 &"))
        machine.wait_for_file(f"/tmp/{name}.window")
        return [int(n) for n in machine.succeed(f"cat /tmp/{name}.window").split()]


    def open_place(file):
        return ask({"op": "launch", "args": ["--task", "EditFile", "--localPlaceFile", file]})


    def running():
        return ask({"op": "list"})["processes"]


    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("sockets.target", "alice")
    machine.wait_for_file(SOCKET)
    machine.succeed(as_alice(f"mkdir -p {PLACES}/baseplates ~/downloads && touch '{PLACES}/baseplates/Base 1.rbxl' ~/downloads/Delivery.rbxl ~/outside.rbxl"))
    machine.succeed(as_alice(f"ln -s ~/outside.rbxl {PLACES}/Linked.rbxl"))

    with subtest("the broker starts on the first request and sees no Studio"):
        machine.fail(ACTIVE)
        assert running() == []
        machine.succeed(ACTIVE)

    with subtest("a place in the places folder opens in a Studio the broker then lists"):
        opened = open_place(f"{PLACES}/baseplates/Base 1.rbxl")
        assert opened["ok"], opened
        assert opened["process"]["commandLine"].endswith("lumen-places\\baseplates\\Base 1.rbxl"), opened
        assert [p["pid"] for p in running()] == [opened["process"]["pid"]]

    with subtest("places elsewhere, through a link or by another task are refused"):
        assert "opens only" in open_place("/home/alice/outside.rbxl")["error"]
        assert "symlinks" in open_place(f"{PLACES}/Linked.rbxl")["error"]
        assert "Only --task" in ask({"op": "launch", "args": ["--task", "Run", "--script", "x"]})["error"]
        assert len(running()) == 1

    with subtest("Studio outlives a broker that left when idle, and the next request finds it"):
        machine.wait_until_fails(ACTIVE, timeout=${toString (idle * 5)})
        machine.succeed(f"kill -0 {opened['process']['pid']}")
        assert running() == [opened["process"]]

    with subtest("a stop ends that Studio alone"):
        assert ask({"op": "stop", "pid": 1, "startedAt": opened["process"]["startedAt"]})["ok"]
        assert len(running()) == 1
        assert ask({"op": "stop", "pid": opened["process"]["pid"], "startedAt": opened["process"]["startedAt"]})["ok"]
        assert running() == []

    with subtest("the lock a killed Studio leaves is removed in a folder no sandbox writes, and only there"):
        for file in ["/home/alice/downloads/Delivery.rbxl", f"{PLACES}/baseplates/Base 1.rbxl"]:
            studio = open_place(file)["process"]
            machine.succeed(as_alice(f"printf 'x\\nRobloxStudioBeta\\n' > '{file}.lock'"))
            assert ask({"op": "stop", "pid": studio["pid"], "startedAt": studio["startedAt"]})["ok"]
        machine.fail("test -e /home/alice/downloads/Delivery.rbxl.lock")
        machine.succeed(f"test -e '{PLACES}/baseplates/Base 1.rbxl.lock'")

    with subtest("the display is reached with the session's cookie"):
        machine.wait_for_unit("xserver.service", "alice")
        machine.wait_for_file("/tmp/.X11-unix/X${displayNumber}")
        machine.fail(as_alice("DISPLAY=${display} XAUTHORITY=/dev/null python3 -c 'from Xlib import display; display.Display()'"))
        machine.succeed(f"systemctl --user -M alice@ set-environment {X11}")
        assert ask({"op": "windows"})["windows"] == []

    with subtest("only a running Studio's windows are listed and grabbed, whatever covers them"):
        studio = open_place(f"{PLACES}/baseplates/Base 1.rbxl")["process"]
        window, holder = show_window("studio", "Base 1 - Roblox Studio", "steam_proton", studio["pid"], "336699")
        decoy, _ = show_window("decoy", "Base 1 - Roblox Studio", "steam_proton", 1, "aa0000")
        other, _ = show_window("other", "Passwords", "keepassxc", 1, "00aa00")
        assert ask({"op": "windows"})["windows"] == [{
            "id": window, "title": "Base 1 - Roblox Studio", "className": "steam_proton steam_proton",
            "pid": studio["pid"], "width": 320, "height": 240, "shown": True,
        }]
        header, colours = grab(window)
        assert header["ok"] and colours == {"336699"}, (header, colours)
        _, colours = grab(window, 16, 8)
        assert colours == {"336699"}, colours
        for refused in [decoy, other, 0, "1"]:
            header, colours = grab(refused)
            assert not header["ok"] and not colours, (refused, header)
            assert not ask({"op": "restore", "window": refused})["ok"]
        assert "rectangle" in grab(window, 0, 240)[0]["error"]
        assert grab(window, 640, 480)[0]["x11"]["code"] == 8

    with subtest("a minimized Studio window is reported, refused with the X server's code and restored"):
        machine.succeed(f"kill -USR1 {holder}")
        machine.wait_until_succeeds(as_alice(
            f"python3 /etc/studio-broker-test/ask.py {SOCKET} '{{\"op\":\"windows\"}}' | grep -q '\"shown\": *false'"), timeout=10)
        assert grab(window)[0]["x11"]["code"] == 8
        assert ask({"op": "restore", "window": window})["ok"]
        assert ask({"op": "windows"})["windows"][0]["shown"]
        assert grab(window)[1] == {"336699"}

    with subtest("a window stops counting once its Studio is gone"):
        assert ask({"op": "stop", "pid": studio["pid"], "startedAt": studio["startedAt"]})["ok"]
        assert ask({"op": "windows"})["windows"] == []
        assert not grab(window)[0]["ok"]
  '';
}
