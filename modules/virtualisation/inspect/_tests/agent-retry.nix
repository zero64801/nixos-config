# nix build --no-link -L .#tests.inspect.agent-retry
# The session helper's agent calls while a debugger halts the guest for moments: a refusal made during one is waited out, any other comes back at once.
{
  host,
}:

host.pkgs.runCommand "vm-inspect-agent-retry" { nativeBuildInputs = [ host.pkgs.python3 ]; } ''
  python3 -I -B ${./agent_retry_logic.py} ${../_inspect_helper.py}
  touch $out
''
