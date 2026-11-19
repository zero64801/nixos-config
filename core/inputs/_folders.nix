# The inputs that folders declare for themselves: an _inputs.nix that says what the folder needs, as it would stand in flake.nix, with an _inputs.lock beside it.
# core: the inputs of flake.nix, which is what a folder's inputs may follow.
{
  lib,
  core,
}:

let
  load = import ./_load.nix;

  # The names one file declares, each bound to the flake its lock gives. Neither the lock nor a source is read before a module reads the input.
  of =
    file:
    let
      lockFile = dirOf file + "/_inputs.lock";
      loaded =
        if builtins.pathExists lockFile then
          load {
            lock = builtins.fromJSON (builtins.readFile lockFile);
            given = core;
          }
        else
          throw "${toString file} has no _inputs.lock beside it, which `nix run .#inputs -- lock` writes";
    in
    lib.mapAttrs (name: _: loaded.${name}) (import file);
in
{
  # files: the _inputs.nix files in view. Gives every input they declare, by name.
  from =
    files:
    let
      each = map of files;
      names = lib.concatMap lib.attrNames each;
      twice = lib.unique (builtins.filter (name: core ? ${name} || lib.count (other: other == name) names > 1) names);
    in
    assert lib.assertMsg (twice == [ ]) "declared more than once, by two folders or by a folder and flake.nix: ${toString twice}";
    lib.foldl' (all: inputs: all // inputs) { } each;
}
