# nix build --no-link .#tests.core.without
# The list of shared folders a host leaves out: read where its file is there, empty where it has none, and refused where a name leaves nothing out.
{
  host,
}:

let
  inherit (host.pkgs) lib;

  some = host.leftOut ./_without/some.nix;
  none = host.leftOut ./_without/no-such-file.nix;
  misspelt = builtins.tryEval (host.leftOut ./_without/misspelt.nix);
in
assert lib.assertMsg (some == [ "core/sudo.nix" ]) "the list was not read";
assert lib.assertMsg (lib.length (host.modules some) == lib.length (host.modules [ ]) - 1) "the module named was not left out";
assert lib.assertMsg (none == [ ]) "a host with no list leaves something out";
assert lib.assertMsg (!misspelt.success) "a name that leaves nothing out was taken";
"ok: a host's list of folders to leave out is read, may be missing, and may hold no name that leaves nothing out"
