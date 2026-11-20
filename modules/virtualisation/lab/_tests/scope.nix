# nix build --no-link -L .#tests.lab.scope
# Which flows guest-net's --process, --children and --host keep, by program, by the programs it started and by host.
{
  host,
}:

host.pkgs.runCommand "guest-net-scope" { nativeBuildInputs = [ host.pkgs.python3 ]; } ''
  python3 -I -B ${./scope_logic.py} ${../_capture}
  touch $out
''
