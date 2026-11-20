# nix build --no-link -L .#tests.lab.scan-run
# keys scan's whole one look on a capture of a QUIC flow that updated its keys and lost many of the server's datagrams, with made up memory in place of the guest's RAM, and guest-net reading the flow with what it noted.
{
  host,
}:

let
  inherit (host) pkgs;
  tlsscan = pkgs.callPackage ../_capture/tlsscan/tlsscan.nix { };
  python = pkgs.python3.withPackages (packages: [ packages.aioquic ]);
in
pkgs.runCommand "guest-net-scan-run" { nativeBuildInputs = [ pkgs.openssl ]; } ''
  cd "$(mktemp -d)"
  ${python}/bin/python3 -I -B ${./scan_run_logic.py} ${../_capture} ${pkgs.wireshark-cli}/bin ${tlsscan}/lib/libtlsscan.so
  touch $out
''
