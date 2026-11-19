# nix build --no-link -L .#tests.lab.schannel
# guest-net's reading of SChannel's keys on a made up stretch of lsass' memory, laid out as the published method describes.
{
  host,
}:

host.pkgs.runCommand "guest-net-schannel" { nativeBuildInputs = [ host.pkgs.python3 ]; } ''
  python3 -I -B ${./schannel_logic.py} ${../_capture}
  touch $out
''
