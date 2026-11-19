# nix build --no-link .#tests.core.made-up-host
# Every shared module on a host that is none of this repository's, and again as a fork has them that deleted any one thing of apps and modules.
{
  flake,
  host,
}:

let
  inherit (flake.inputs.nixpkgs) lib;

  # What a system here cannot do without: the other modules write to the first three, and the two of virtualisation need each other and carry the rest of it.
  frame = [
    "modules/home-manager.nix"
    "modules/impermanence"
    "modules/persistence.nix"
    "modules/virtualisation/base.nix"
    "modules/virtualisation/nixvirt.nix"
  ];

  # Each thing a fork can delete: a folder, and each module file of a folder that only gathers things.
  # A folder with a module of its own name, or a default.nix, is one thing, and the files in it are its parts.
  below =
    folder:
    let
      found = builtins.readDir "${flake}/${folder}";
      one = found ? "default.nix" || found ? "${baseNameOf folder}.nix";
    in
    lib.concatLists (
      lib.mapAttrsToList (
        name: kind:
        if lib.hasPrefix "_" name then
          [ ]
        else if kind == "directory" then
          [ "${folder}/${name}" ] ++ below "${folder}/${name}"
        else if !one && lib.hasSuffix ".nix" name && name != "flake.nix" then
          [ "${folder}/${name}" ]
        else
          [ ]
      ) found
    );
  entries = lib.subtractLists frame (lib.concatMap below (builtins.filter (folder: builtins.pathExists "${flake}/${folder}") [ "apps" "modules" ]));

  evaluates = made: lib.isString made.config.system.build.toplevel.drvPath;
  all = lib.length (host.modules [ ]);
  survives =
    entry:
    builtins.addErrorContext "with ${entry} deleted" (
      lib.length (host.modules [ entry ]) < all && evaluates (host.evaluate { without = [ entry ]; })
    );

  whole = evaluates (host.evaluate { });
  missed = builtins.filter (
    entry:
    let
      tried = builtins.tryEval (survives entry);
    in
    !tried.success || !tried.value
  ) entries;
in
assert lib.assertMsg whole "the made up host does not evaluate";
assert lib.assertMsg (missed == [ ]) "the made up host does not evaluate with one of these deleted: ${toString missed}";
# The things follow the first line, one a line, for whatever wants to try more with each of them gone.
lib.concatStringsSep "\n" (
  [ "ok: the made up host evaluates, and with any one of these ${toString (lib.length entries)} things deleted:" ] ++ entries
)
