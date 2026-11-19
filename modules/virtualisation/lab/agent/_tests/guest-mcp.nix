# nix build --no-link -L .#tests.agent.guest-mcp
# guest-mcp against a real guest, on the machine the tests of a session share, with a program in that guest talked to.
{
  host,
}:

let
  inherit (host) pkgs;

  # Answers every line it reads with a line of its own, the way a server that is talked to does.
  talker = pkgs.writeText "talker.sh" ''
    while read -r line; do
      echo "{\"said\": \"$GREETING from $(id -un)\", \"to\": $line}"
    done
  '';
in
host.needs [ "modules/virtualisation/inspect" ] (
  import ../../../inspect/_tests/fixture.nix { inherit host; } {
    name = "guest-mcp";
    tools = library: [ (pkgs.callPackage ../_guest-mcp.nix { } library) ];

    testScript = ''
      start_driven()

      with subtest("a program in the guest that speaks in lines of JSON is talked to from this side, and leaves nothing behind"):
          out = machine.succeed(session("--control", "; ".join([
              "guest-push ${talker} /tmp/talker > /dev/null",
              "( echo '{\"id\": 1, \"method\": \"first\"}'; sleep 4; echo '{\"id\": 2, \"method\": \"second\"}'; sleep 4 ) | guest-mcp --user tester --env GREETING=hello /bin/sh /tmp/talker; echo talked=$?",
              "guest-job status | sed 's/^[0-9a-f]* /job/'; guest-find /run/vm-inspect-jobs '*' | sed 's/^/found /'; echo left",
          ])))
          print(out)
          for wanted in ['{"said":"hello from tester","to":{"id":1,"method":"first"}}', '{"said":"hello from tester","to":{"id":2,"method":"second"}}', "talked=0"]:
              assert wanted in out, f"{wanted} is missing from: {out}"
          assert not re.search(r"^job ", out, re.MULTILINE) and "found /run/vm-inspect-jobs/" not in out, f"the program's job was left behind: {out}"
    '';
  }
)
