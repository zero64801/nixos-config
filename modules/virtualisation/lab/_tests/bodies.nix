# nix build --no-link -L .#tests.lab.bodies
# How guest-net undoes the encodings of HTTP bodies, gzip, deflate, brotli and zstd, alone and chained, and stops at a limit for a body made to grow without end, and how it lays out JSON.
{
  host,
}:

let
  inherit (host) pkgs;
  python = pkgs.python3.withPackages (packages: [ packages.brotli ]);
in
pkgs.runCommand "guest-net-bodies" { } ''
  ${python}/bin/python3 -I -B ${./bodies_logic.py} ${../_capture}
  touch $out
''
