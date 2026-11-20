# nix build --no-link -L .#tests.lab.websocket
# guest-net ws on a WebSocket of HTTP/1 with permessage-deflate and fragments, read through the real tshark, one of HTTP/3 read from its stream, and a hostile guest's frames.
{
  host,
}:

let
  inherit (host) pkgs;
  python = pkgs.python3.withPackages (packages: [ packages.brotli ]);
in
pkgs.runCommand "guest-net-websocket" { } ''
  cd "$(mktemp -d)"
  ${python}/bin/python3 -I -B ${./websocket_logic.py} ${../_capture} ${pkgs.wireshark-cli}/bin
  touch $out
''
