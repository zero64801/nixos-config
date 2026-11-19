# nix build --no-link -L .#tests.lab.owners
# How guest-net owners reads what the guest's own tools print, in Linux and in Windows, and which flow it puts each program to.
{
  host,
}:

host.pkgs.runCommand "guest-net-owners" { nativeBuildInputs = [ host.pkgs.python3 ]; } ''
  python3 -I -B ${./owners_logic.py} ${../_capture}
  touch $out
''
