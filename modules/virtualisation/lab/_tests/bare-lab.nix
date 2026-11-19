# nix build --no-link -L .#tests.lab.bare-lab
# vm-lab run on a system that has no confine module: no sandbox, and still the tools, mounts of its own, lab-box and a mode another module adds.
{
  host,
}:

let
  inherit (host) pkgs;

  # Stands in for vm-inspect, which wants a guest and an administrator: it opens nothing and runs the command as a session would.
  session = pkgs.writeShellScriptBin "vm-inspect" ''
    joining=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --join) joining=1 ;;
        --gdb | --control) ;;
        *) break ;;
      esac
      shift
    done
    domain=$1
    shift 2
    if [ -n "$joining" ]; then
      exit 1
    fi
    export VM_INSPECT_DOMAIN="$domain" VM_INSPECT_DIR=/nowhere VM_INSPECT_DEVICE=none VM_INSPECT_GDB=none
    exec "$@"
  '';

  guestTools = pkgs.writeShellScriptBin "guest-exec" ''
    echo "guest-exec stands in"
  '';
in
host.boot {
  name = "vm-lab-bare";
  # Its own module is stood in for below, yet the MemProcFS the lab hands out is built from that folder.
  needs = [ "modules/virtualisation/inspect" ];

  # The made up host as a fork has it that deleted confine, and without the agent's folder, which builds on the real vm-inspect.
  without = [
    "apps/confine"
    "modules/virtualisation/inspect"
    "modules/virtualisation/lab/agent"
  ];

  machines.machine =
    { config, lib, ... }:
    {
      # Stands in for vm-inspect's module, of which the lab takes these options alone.
      options.my.virtualisation.inspect = {
        enable = lib.mkEnableOption "the stand in for vm-inspect";
        package = lib.mkOption { type = lib.types.package; };
        guestTools = lib.mkOption { type = lib.types.package; };
        memprocfs = lib.mkOption { type = lib.types.package; };
      };

      config = {
        my.virtualisation.inspect = {
          enable = true;
          package = session;
          inherit guestTools;
          # The real one, which is the tool the lab is for and needs no guest to be built.
          memprocfs = pkgs.callPackage ../../inspect/_memprocfs/memprocfs.nix { };
        };
        my.virtualisation.lab = {
          enable = true;
          modes.note = {
            summary = "start with a notebook that is kept";
            kept.lab-notes = ".notes";
            start = ''set -- echo "note for $domain:" "$@"'';
          };
        };

        # vm-lab asks Nix for its tools, which this machine has and cannot fetch.
        virtualisation.additionalPaths = [ config.system.build.vmLabTools ];
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        nix.settings.substituters = lib.mkForce [ ];

        virtualisation.memorySize = 2048;
        environment.systemPackages = [ pkgs.bindfs ];
        users.users.alice = {
          uid = 1000;
          linger = true;
        };
      };
    };

  testScript = ''
    def alice(command):
        return f"su - alice -c 'export XDG_RUNTIME_DIR=/run/user/1000; {command}'"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.succeed(alice("echo kept > note"))

    with subtest("the lab opens with no sandbox and says so"):
        out = machine.succeed(alice("vm-lab guest < /dev/null 2>&1"))
        print(out)
        assert "guest is open in this shell" in out, out
        assert "there is no sandbox on this system" in out, out
        machine.fail(alice("vm-lab --join guest true"))

    with subtest("the tools are on the path, in the folder it was started in, with the user's own files"):
        out = machine.succeed(alice("vm-lab guest sh -c \"echo domain=\\$VM_INSPECT_DOMAIN; command -v guest-mount guest-ps lab-box memprocfs; guest-exec; pwd; cat note\""))
        print(out)
        for wanted in ["domain=guest", "-vm-lab-tools/bin/guest-mount", "-vm-lab-tools/bin/guest-ps", "-vm-lab-tools/bin/lab-box",
                       "-vm-lab-tools/bin/memprocfs", "guest-exec stands in", "/home/alice\n", "kept"]:
            assert wanted in out, f"{wanted} is missing from: {out}"

    with subtest("a program in the lab mounts a filesystem with no helper, and the mount stays in the lab"):
        out = machine.succeed(alice("mkdir -p from to; echo through > from/file; vm-lab guest sh -c \"bindfs from to && cat to/file\""))
        print(out)
        assert "through" in out, out
        machine.succeed("[ -z \"$(ls /home/alice/to)\" ]")

    with subtest("lab-box still shuts a program off from the user's files and refuses the system's loopback"):
        out = machine.fail(alice("vm-lab guest lab-box -- cat /home/alice/note 2>&1"))
        assert "No such file" in out, out
        out = machine.succeed(alice("vm-lab guest lab-box --ro /home/alice/note -- cat /home/alice/note"))
        assert "kept" in out, out
        out = machine.fail(alice("vm-lab guest lab-box --share-loopback -- true 2>&1"))
        assert "this lab has no sandbox" in out, out

    with subtest("a mode another module added starts what it names, and gets its folder"):
        out = machine.succeed(alice("vm-lab --note guest one two"))
        assert "note for guest: one two" in out, out
        machine.succeed("test -d /home/alice/.local/state/lab-notes")
  '';
}
