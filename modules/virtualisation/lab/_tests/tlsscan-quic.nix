# nix build --no-link -L .#tests.lab.tlsscan-quic
# keys scan's search on QUIC of aioquic, in every cipher of TLS 1.3 and in QUIC versions 1 and 2, and of curl on ngtcp2, with the secrets of each client's own key log hidden in made up memory.
{
  host,
}:

let
  inherit (host) pkgs;
  tlsscan = pkgs.callPackage ../_capture/tlsscan/tlsscan.nix { };
  python = pkgs.python3.withPackages (packages: [ packages.aioquic ]);
in
pkgs.runCommand "guest-net-tlsscan-quic" { nativeBuildInputs = [ pkgs.openssl ]; } ''
  cd "$(mktemp -d)"
  ${python}/bin/python3 -I -B ${./tlsscan_quic_logic.py} ${../_capture} ${tlsscan}/lib/libtlsscan.so ${pkgs.curl.bin}/bin/curl
  touch $out
''
