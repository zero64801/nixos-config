# nix build --no-link -L .#tests.agent.agent
# The lab's agent on a system that is none of this repository's hosts: turned on with that system's own values, left off, and without a sandbox.
{
  host,
}:

let
  inherit
    (import ../../_tests/fixture.nix { inherit host; })
    pkgs
    evalWith
    opened
    command
    failures
    settings
    ;
  inherit (pkgs) lib;

  agent = {
    enable = true;
    # Stands in for Claude Code, which this needs to name and never starts.
    package = pkgs.hello;
    tokenFile = "/tmp/lab secrets/agent token";
    proxy = 8080;
  };

  staffed = evalWith { } {
    inspect = opened;
    lab = {
      enable = true;
      inherit agent;
    };
  };

  idle = evalWith { } {
    inspect = opened;
    lab.enable = true;
  };

  removed = evalWith { without = [ "modules/virtualisation/lab/agent" ]; } {
    inspect = opened;
    lab.enable = true;
  };

  bare = evalWith { without = [ "apps/confine" ]; } {
    inspect = opened;
    lab = {
      enable = true;
      inherit agent;
    };
  };

  ungated = evalWith { without = [ "apps/proxy/host-gate" ]; } {
    inspect = opened;
    lab = {
      enable = true;
      inherit agent;
    };
  };

  lab = config: config.my.virtualisation.lab.package;
  kept = config: config.my.persistence.home.directories;

  checks = {
    agentThatIsOffLeavesNoTrace =
      !lib.hasInfix "--agent" (lab idle).text
      && command "vm-lab-agent" idle == null
      && !lib.elem ".local/state/vm-lab-agent" (kept idle);
    guestMcpComesWithTheFolderAlone =
      idle.my.virtualisation.lab.tools ? guest-mcp && !(removed.my.virtualisation.lab.tools ? guest-mcp);
    agentComesWithItsCommandAndItsState =
      command "vm-lab-agent" staffed != null && lib.elem ".local/state/vm-lab-agent" (kept staffed);
    agentWithoutSandboxIsRefused = failures "my.virtualisation.lab.sandbox" bare != [ ];
    agentWithoutHostGateIsRefused = failures "no host-gate module" ungated != [ ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
  # What the agent itself refuses, said before anything else is looked at.
  refused = map (a: a.message) (failures "my.virtualisation.lab" staffed);
in
host.needs [ "apps/confine" "apps/proxy/host-gate" "modules/virtualisation/inspect" ] (
  assert lib.assertMsg (refused == [ ]) "the agent cannot be built here: ${lib.concatStringsSep " " refused}";
  assert lib.assertMsg (failed == [ ]) "vm-lab agent checks failed: ${lib.concatStringsSep ", " failed}";
  pkgs.runCommand "vm-lab-agent-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    ${settings}
    PATH=${idle.my.virtualisation.lab.tools.guest-mcp.package}/bin:$PATH python3 -I -B ${./hostile_mcp.py}
    ${lab idle}/bin/vm-lab --help | grep -q "^  guest-mcp     a program in the guest"
    if ${lab removed}/bin/vm-lab --help | grep -q guest-mcp; then
      echo "a lab without this folder speaks of guest-mcp"
      exit 1
    fi

    staffed=${lab staffed}/bin/vm-lab
    agent=${command "vm-lab-agent" staffed}/bin/vm-lab-agent

    "$staffed" --help > staffed.help
    grep -q -- "  --agent    start Claude Code inside the lab" staffed.help
    grep -q -- "--through 127.0.0.1:8080" "$staffed"
    run=$(grep -o '/nix/store/[a-z0-9]*-vm-lab-agent-run' "$staffed" | head -n 1)
    grep -q "door 127.0.0.1:8080" "''${run:?}"
    grep -q "exec ${lib.getExe pkgs.hello} " "$run"
    told=$(grep -o '/nix/store/[a-z0-9]*-_agent.md' "$run" | head -n 1)
    grep -q "guest-exec" "''${told:?}"

    inside=$(settings "$staffed" ---agent)
    outside=$(settings "$staffed" ----)
    grep -q '"xdg-state/vm-lab-agent"' "$inside"
    grep -q '".claude-agent"' "$inside"
    if grep -q "skills" "$inside"; then
      echo "the agent's sandbox holds a folder of the user's Claude Code settings"
      exit 1
    fi
    if grep -q claude-agent "$outside"; then
      echo "a lab without the agent holds the agent's folder"
      exit 1
    fi

    "$agent" --help > agent.help
    grep -q -- "--token" agent.help
    grep -q "exec ${lab staffed}/bin/vm-lab --agent " "$agent"
    printf 'fixture-token\n' | "$agent" --token
    [ "$(cat "/tmp/lab secrets/agent token")" = fixture-token ]
    [ "$(stat -c %a "/tmp/lab secrets/agent token")" = 600 ]

    touch $out
  ''
)
