# nix build --no-link -L .#tests.host-gate.host-gate
{
  host,
}:

let
  inherit (host) pkgs;
  inherit (host.evaluate { }) config;
in
pkgs.runCommand "host-gate-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 -I -B ${./gate_flow.py} ${config.my.apps.hostGate.package}/bin/host-gate
  touch $out
''
