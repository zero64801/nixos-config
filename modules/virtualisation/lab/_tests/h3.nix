# nix build --no-link -L .#tests.lab.h3
# guest-net's reading of HTTP/3 from curl and aioquic's server with only the traffic secrets, and h3.py on its own with headers that wait on the table, pieces out of order and a hostile guest's bytes.
{
  host,
}:

let
  inherit (host) pkgs;
  python = pkgs.python3.withPackages (packages: [
    packages.aioquic
    packages.brotli
    packages.pylsqpack
  ]);
in
pkgs.runCommand "guest-net-h3" { nativeBuildInputs = [ pkgs.openssl ]; } ''
  cd "$(mktemp -d)"
  ${python}/bin/python3 -I -B ${./h3_logic.py} ${../_capture} ${pkgs.wireshark-cli}/bin ${pkgs.curl.bin}/bin/curl
  touch $out
''
