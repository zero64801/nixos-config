{ inputs }:

let
  lib = inputs.nixpkgs.lib;

  importDir = dir:
    let
      allFiles = lib.filesystem.listFilesRecursive dir;
      relParts = f: lib.splitString "/" (lib.removePrefix (toString dir + "/") (toString f));
      nixFiles = builtins.filter (f:
        let name = baseNameOf (toString f); in
        lib.hasSuffix ".nix" (toString f)
        && name != "flake.nix"
        && !lib.any (lib.hasPrefix "_") (relParts f)
      ) allFiles;
    in nixFiles;

  shared = importDir ./core ++ importDir ./apps ++ importDir ./modules;

  # Files without those that lie in the folders named or are the module files named, as "modules/stylix".
  drop =
    without:
    builtins.filter (
      file: !lib.any (gone: toString file == "${toString ./.}/${gone}" || lib.hasPrefix "${toString ./.}/${gone}/" (toString file)) without
    );

  keep = without: drop without shared;

  # The _inputs.nix files below a folder, in which a folder says what it needs beyond the inputs of flake.nix.
  declaredIn =
    dir:
    builtins.filter (
      file:
      baseNameOf (toString file) == "_inputs.nix"
      && !lib.any (lib.hasPrefix "_") (lib.init (lib.splitString "/" (lib.removePrefix (toString dir + "/") (toString file))))
    ) (lib.optionals (builtins.pathExists dir) (lib.filesystem.listFilesRecursive dir));

  declared = declaredIn ./core ++ declaredIn ./apps ++ declaredIn ./modules;

  folders = import ./core/inputs/_folders.nix {
    inherit lib;
    core = removeAttrs inputs [ "self" ];
  };

  # What the modules of a host are handed as inputs: those of flake.nix, those of the shared folders it loads, and those its own folder declares.
  inputsOf =
    hostName: inputs // folders.from (drop (leftOut ./hosts/${hostName}/_without.nix) declared ++ declaredIn ./hosts/${hostName});

  # What a host leaves out of the shared modules: the list in the file given, its _without.nix, and nothing where it has no such file.
  # A name there that leaves nothing out is a mistake and is said, since nothing else would show it.
  leftOut =
    file:
    let
      named = if builtins.pathExists file then import file else [ ];
      idle = builtins.filter (gone: lib.length (keep [ gone ]) == lib.length shared) named;
    in
    assert lib.assertMsg (idle == [ ])
      "${lib.removePrefix "${toString ./.}/" (toString file)} names what is no shared folder or module file: ${toString idle}";
    named;

  hostnames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
  );

  specialArgs = hostName: {
    inputs = inputsOf hostName;
    inherit hostName;
  };

  system = hostName: modules:
    lib.nixosSystem {
      specialArgs = specialArgs hostName;
      inherit modules;
    };

in
{
  # The shared modules and how a system is made of them, for whatever builds a system that is no host here, as the tests do.
  inherit keep leftOut specialArgs system;

  nixosConfigurations = lib.genAttrs hostnames (hostname: system hostname (keep (leftOut ./hosts/${hostname}/_without.nix) ++ importDir ./hosts/${hostname}));
}
