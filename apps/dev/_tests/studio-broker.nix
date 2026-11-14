# nix build --impure --no-link -L --expr 'import ./apps/dev/_tests/studio-broker.nix { }'
# The broker behind its socket, with a stand-in for Vinegar's Flatpak that turns into a process named like Studio.
{
  pkgs ? (builtins.getFlake (toString ../../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  idle = 3;

  # flatpak run --branch --arch --command org.vinegarhq.Vinegar run, then Studio's own arguments.
  flatpak = pkgs.writeShellScriptBin "flatpak" ''
    shift 6
    exec -a 'C:\Program Files\Roblox\RobloxStudioBeta.exe' ${pkgs.runtimeShell} -c \
      'while :; do ${pkgs.coreutils}/bin/sleep 0.2; done' studio "$@"
  '';
in
pkgs.testers.runNixOSTest {
  name = "studio-broker";

  nodes.machine = {
    imports = [ ../studio-broker.nix ];

    my.apps.studioBroker = {
      enable = true;
      lockFolders = [ "downloads" ];
      idleTimeout = idle;
    };

    users.users.alice = {
      isNormalUser = true;
      linger = true;
    };

    environment.systemPackages = [
      flatpak
      pkgs.python3
    ];
    environment.etc."studio-broker-test/ask.py".source = ./studio_ask.py;
  };

  testScript = ''
    import json
    import shlex

    SOCKET = "/run/user/1000/studio-broker/socket"
    PLACES = "/home/alice/.var/app/org.vinegarhq.Vinegar/data/lumen-places"
    ACTIVE = "systemctl --user -M alice@ is-active studio-broker.service"


    def as_alice(command):
        return "su - alice -c " + shlex.quote(command)


    def ask(request):
        command = f"python3 /etc/studio-broker-test/ask.py {SOCKET} {shlex.quote(json.dumps(request))}"
        return json.loads(machine.succeed(as_alice(command)))


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
  '';
}
