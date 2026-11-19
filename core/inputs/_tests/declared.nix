# nix build --no-link .#tests.inputs.declared
# What the folders of this repository declare for themselves: each name once, each with a lock that holds it, and no module that reads an input nobody declares.
{
  flake,
  host,
}:

let
  inherit (host.pkgs) lib;

  own = lib.attrNames (import "${flake}/flake.nix").inputs;

  files = lib.concatMap (
    folder: lib.optionals (builtins.pathExists "${flake}/${folder}") (map toString (lib.filesystem.listFilesRecursive "${flake}/${folder}"))
  ) [ "core" "apps" "modules" "hosts" ];
  # confine and flatlock are flakes of their own, with inputs of their own.
  ours = builtins.filter (file: !lib.any (apart: lib.hasPrefix "${flake}/${apart}/" file) [ "apps/confine" "apps/flatlock" ]) files;

  declarations = builtins.filter (file: baseNameOf file == "_inputs.nix") ours;
  place = file: lib.removePrefix "${flake}/" (dirOf file);
  names = lib.concatMap (file: lib.attrNames (import file)) declarations;
  twice = lib.unique (builtins.filter (name: lib.elem name own || lib.count (other: other == name) names > 1) names);

  unlocked = builtins.filter (
    file:
    let
      lockFile = dirOf file + "/_inputs.lock";
      lock = builtins.fromJSON (builtins.readFile lockFile);
      held = name: lock.nodes ? ${lock.nodes.${lock.root}.inputs.${name} or "none"};
    in
    !builtins.pathExists lockFile || !lib.all held (lib.attrNames (import file))
  ) declarations;

  # Every name that stands behind the word inputs and a dot in a Nix file, which is how a module reaches an input.
  read =
    file:
    lib.concatMap (found: lib.optional (lib.isList found) (lib.elemAt found 1)) (
      builtins.split "(^|[^A-Za-z0-9_.])inputs\\.([A-Za-z0-9_-]+)" (builtins.readFile file)
    );
  known = own ++ names ++ [ "self" ];
  strangers = lib.concatMap (
    file: map (name: "${lib.removePrefix "${flake}/" file} reads ${name}") (lib.subtractLists known (lib.unique (read file)))
  ) (builtins.filter (lib.hasSuffix ".nix") ours);
in
assert lib.assertMsg (twice == [ ]) "declared more than once, by two folders or by a folder and flake.nix: ${toString twice}";
assert lib.assertMsg (unlocked == [ ]) "without a lock that holds what they declare, which `nix run .#inputs -- lock` writes: ${toString (map place unlocked)}";
assert lib.assertMsg (strangers == [ ]) "an input that neither flake.nix nor a folder's _inputs.nix declares: ${lib.concatStringsSep ", " strangers}";
"ok: ${toString (lib.length names)} inputs declared by ${toString (lib.length declarations)} folders beside the ${toString (lib.length own)} of flake.nix, each locked, and no module reads another"
