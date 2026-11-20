# nix build --no-link -L .#tests.lab.own-keys
# keys own: libtlsscan finds the key of each cipher it knows among made up noise with each check a decoder sets, own.py refuses tests that do not fit, and keys own as a whole judges a weak test's windows with a decoder, notes the two keys of a made up capture, which decode then hands to it.
{
  host,
}:

let
  inherit (host) pkgs;
  tlsscan = pkgs.callPackage ../_capture/tlsscan/tlsscan.nix { };
  python = pkgs.python3.withPackages (packages: [
    packages.cryptography
    packages.pynacl
  ]);
in
pkgs.runCommand "guest-net-own-keys" { } ''
  cd "$(mktemp -d)"
  ${python}/bin/python3 -I -B ${./own_logic.py} ${../_capture} ${pkgs.wireshark-cli}/bin ${tlsscan}/lib/libtlsscan.so ${./own_decoder.py}
  touch $out
''
