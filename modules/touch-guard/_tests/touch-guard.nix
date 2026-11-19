# nix build --no-link -L .#tests.touch-guard.touch-guard
{
  host,
}:

let
  inherit (host) pkgs;
in
pkgs.runCommand "touch-guard-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 -I ${./test_touch_guard.py} ${./..}
  touch $out
''
