# nix build --no-link -L .#tests.inspect.symbols
# The symbol gateway and the patched pdbcrust: what is fetched and refused, and several readers on one empty cache at once.
{
  host,
}:

(host.pkgs.callPackage ../_memprocfs/memprocfs.nix { }).tests.symbolGateway
