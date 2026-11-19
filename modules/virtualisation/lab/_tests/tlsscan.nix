# nix build --no-link -L .#tests.lab.tlsscan
# keys scan's search on traffic of OpenSSL in every suite it knows, with the secrets of OpenSSL's own key log hidden in made up memory.
{
  host,
}:

let
  inherit (host) pkgs;
  tlsscan = pkgs.callPackage ../_capture/tlsscan/tlsscan.nix { };
in
pkgs.runCommand "guest-net-tlsscan" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  cd "$(mktemp -d)"
  python3 -I -B ${./tlsscan_logic.py} ${../_capture} ${tlsscan}/lib/libtlsscan.so ${pkgs.openssl.bin}/bin/openssl
  touch $out
''
