# The text of a throwaway flake for locking one folder's inputs: what the folder declares, beside the inputs of flake.nix at the revisions they are locked at, which is what a follows points at.
{
  declared,
  flake,
  lock,
}:

let
  root = builtins.fromJSON (builtins.readFile lock);
  own = (import flake).inputs;

  core = builtins.mapAttrs (
    name: said:
    removeAttrs root.nodes.${root.nodes.${root.root}.inputs.${name}}.locked [ "lastModified" ]
    // (if said ? inputs then { inherit (said) inputs; } else { })
  ) own;

  quoted = text: "\"" + builtins.replaceStrings [ "\\" "\"" "\${" ] [ "\\\\" "\\\"" "\\\${" ] text + "\"";
  render =
    value:
    if builtins.isAttrs value then
      "{ " + builtins.concatStringsSep "" (map (name: "${quoted name} = ${render value.${name}}; ") (builtins.attrNames value)) + "}"
    else if builtins.isString value then
      quoted value
    else if builtins.isBool value then
      (if value then "true" else "false")
    else
      toString value;
in
''
  {
    inputs = ${render (core // import declared)};
    outputs = _: { };
  }
''
