# Loads the flakes a lock names, as Nix does for the inputs of flake.nix: each is fetched and called only once something reads it.
# lock: what a file in the format of flake.lock holds.
# given: flakes by the name the lock's root knows them under, taken in place of whatever the lock says of them.
# fetch: what turns a node's locked attributes into a source, which a test stands in for.
{
  lock,
  given,
  fetch ? builtins.fetchTree,
}:

let
  inherit (lock) nodes;
  rootInputs = nodes.${lock.root}.inputs or { };

  # A reference is a node's name, or a path of input names walked from the root, which is how a lock writes follows.
  resolve = ref: if builtins.isString ref then ref else walk lock.root ref;
  walk = at: path: if path == [ ] then at else walk (resolve nodes.${at}.inputs.${builtins.head path}) (builtins.tail path);

  handed = builtins.listToAttrs (
    map (name: {
      name = resolve rootInputs.${name};
      value = given.${name};
    }) (builtins.filter (name: rootInputs ? ${name}) (builtins.attrNames given))
  );

  load =
    key:
    let
      node = nodes.${key};
      tree = fetch ((node.info or { }) // removeAttrs node.locked [ "dir" ]);
      outPath = tree + (if node.locked ? dir then "/" + node.locked.dir else "");
      inputs = builtins.mapAttrs (_: ref: all.${resolve ref}) (node.inputs or { });
      outputs = (import (outPath + "/flake.nix")).outputs (inputs // { self = result; });
      result =
        outputs
        // tree
        // {
          inherit outPath inputs outputs;
          sourceInfo = tree;
          _type = "flake";
        };
    in
    if node.flake or true then
      result
    else
      tree
      // {
        inherit outPath;
        sourceInfo = tree;
      };

  # A node that is handed in may be missing from the lock altogether, so the lock's own names come second.
  all = builtins.mapAttrs (key: _: load key) nodes // handed;
in
builtins.mapAttrs (_: ref: all.${resolve ref}) rootInputs
