# Every test of the repository, found by where it lies and how it begins, and each given what it asks for.
# A test is a .nix file in a folder named _tests whose first line is the command that runs it, and it is named after the folder that the _tests folder is in.
{
  flake,
  system,
}:

let
  inherit (flake.inputs.nixpkgs) lib;
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  host = import ./system.nix { inherit flake system; };
  given = {
    inherit flake system pkgs host;
  };

  folders = builtins.filter (folder: builtins.pathExists "${flake}/${folder}") [
    "core"
    "apps"
    "modules"
    "hosts"
  ];
  files = builtins.filter (
    file:
    baseNameOf (dirOf file) == "_tests" && lib.hasSuffix ".nix" file && lib.hasPrefix "# nix " (builtins.readFile file)
  ) (lib.concatMap (folder: map toString (lib.filesystem.listFilesRecursive "${flake}/${folder}")) folders);

  test =
    file:
    let
      # A name may not carry the store path that the file's own path does.
      thing = builtins.unsafeDiscardStringContext (baseNameOf (dirOf (dirOf file)));
      name = builtins.unsafeDiscardStringContext (lib.removeSuffix ".nix" (baseNameOf file));
      run = import file;
      made = run (builtins.intersectAttrs (builtins.functionArgs run) given);
    in
    {
      inherit thing name;
      # A test that only evaluates gives its verdict as text, which a build then holds.
      value = if lib.isString made then pkgs.runCommand "${thing}-${name}" { } "echo ${lib.escapeShellArg made} > $out" else made;
    };

  tests = map test files;
  names = map (t: "${t.thing}.${t.name}") tests;
  byThing = lib.mapAttrs (_: found: lib.listToAttrs (map (t: lib.nameValuePair t.name t.value) found)) (lib.groupBy (t: t.thing) tests);
in
assert lib.assertMsg (lib.allUnique names) "two tests have the same name: ${toString (lib.subtractLists (lib.unique names) names)}";
byThing
// {
  all = pkgs.linkFarm "tests" (lib.listToAttrs (map (t: lib.nameValuePair "${t.thing}.${t.name}" t.value) tests));
}
