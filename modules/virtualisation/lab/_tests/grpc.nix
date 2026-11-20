# nix build --no-link -L .#tests.lab.grpc
# gRPC in guest-net: messages by their wire format and named by protoc, a call of HTTP/3 with a gzipped message and its status, gRPC-Web's text, and a hostile guest's bytes.
{
  host,
}:

let
  inherit (host) pkgs;
  python = pkgs.python3.withPackages (packages: [ packages.brotli ]);
in
pkgs.runCommand "guest-net-grpc" { } ''
  cd "$(mktemp -d)"
  ${python}/bin/python3 -I -B ${./grpc_logic.py} ${../_capture} ${pkgs.protobuf}/bin/protoc
  touch $out
''
