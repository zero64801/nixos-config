# nix build --no-link -L .#tests.inputs.lock
# The command that locks what folders declare, on a made up repository with git repositories for inputs and no network: lock, update, set, and that a lock it writes is one the loader reads.
{
  host,
}:

let
  inherit (host) pkgs;
  inherit ((host.evaluate { }).config.nix) package;
  tool = pkgs.callPackage ../_lock.nix { };
in
pkgs.runCommand "flake-inputs-test"
  {
    nativeBuildInputs = [
      tool
      package
      pkgs.git
      pkgs.jq
    ];
  }
  ''
    source ${./_made-up-repo.sh}
    one=$repo/things/one/_inputs.lock
    two=$repo/things/two/_inputs.lock

    # What the loader of this repository makes of the two folders, with a stand in handed in for the input of flake.nix.
    loaded() {
      nix eval --impure --raw --expr "
        let
          folders = import ${../.}/_folders.nix {
            lib = import ${pkgs.path}/lib;
            core.base.said = \"the base handed in\";
          };
          inputs = folders.from [ $repo/things/one/_inputs.nix $repo/things/two/_inputs.nix ];
        in
        inputs.$1"
    }

    echo "nothing is locked at first, and lock writes a lock for each folder"
    flake-inputs --flake "$repo" list > listed
    grep -q "dep.*things/one.*not locked" listed || fail "an unlocked input is not listed as such: $(cat listed)"
    flake-inputs --flake "$repo" lock
    [ "$(locked "$one" dep)" = "$(revision_of dep)" ] || fail "dep is not locked at its revision"
    [ "$(locked "$two" other)" = "$(revision_of other)" ] || fail "other is not locked at its revision"
    flake-inputs --flake "$repo" list > listed
    grep -q "dep.*things/one.*$(revision_of dep | cut -c1-12)" listed || fail "the list does not show the revision: $(cat listed)"

    echo "a lock holds the folder's own inputs and none of flake.nix, which a follows only names"
    [ "$(jq -c '.nodes | keys' "$one")" = '["dep","root"]' ] || fail "the lock of one holds $(jq -c '.nodes | keys' "$one")"
    [ "$(jq -c '.nodes.dep.inputs.base' "$one")" = '["base"]' ] || fail "dep does not follow base"

    echo "the loader reads what was written, and hands dep the base of flake.nix"
    [ "$(loaded dep.saw)" = "the base handed in" ] || fail "dep saw $(loaded dep.saw)"
    [ "$(loaded other.said)" = "other as it was first" ] || fail "other said $(loaded other.said)"

    echo "lock moves nothing that is locked, though its source has moved on"
    move_on other "other, moved on"
    move_on dep "dep, moved on"
    before=$(cat "$one" "$two" | sha256sum)
    said=$(flake-inputs --flake "$repo" lock 2> /dev/null)
    [ -z "$said" ] && [ "$(cat "$one" "$two" | sha256sum)" = "$before" ] || fail "lock wrote: $said"

    echo "update moves the input named and leaves the other folder alone"
    flake-inputs --flake "$repo" update other
    [ "$(locked "$two" other)" = "$(revision_of other)" ] || fail "other was not moved"
    [ "$(locked "$one" dep)" != "$(revision_of dep)" ] || fail "dep was moved with it"
    [ "$(loaded other.said)" = "other, moved on" ] || fail "other said $(loaded other.said)"

    echo "set locks an input to a revision given"
    first=$(git -C "$sources/other" rev-list --max-parents=0 HEAD)
    flake-inputs --flake "$repo" set other "git+file://$sources/other?rev=$first"
    [ "$(locked "$two" other)" = "$first" ] || fail "other is not at the revision set"
    [ "$(loaded other.said)" = "other as it was first" ] || fail "other said $(loaded other.said)"

    echo "a revision that was set stays through a lock and through the update of an input beside it"
    flake-inputs --flake "$repo" lock
    [ "$(locked "$two" other)" = "$first" ] || fail "lock moved other off the revision set"
    move_on mate "mate, moved on"
    flake-inputs --flake "$repo" update mate
    [ "$(locked "$two" mate)" = "$(revision_of mate)" ] || fail "mate was not moved"
    [ "$(locked "$two" other)" = "$first" ] || fail "the update of mate moved other off the revision set"

    echo "an update by name takes an input off the revision set"
    flake-inputs --flake "$repo" update other
    [ "$(locked "$two" other)" = "$(revision_of other)" ] || fail "other stayed at the revision set"
    flake-inputs --flake "$repo" set other "git+file://$sources/other?rev=$first"

    echo "update with no name moves every input"
    flake-inputs --flake "$repo" update
    [ "$(locked "$one" dep)" = "$(revision_of dep)" ] && [ "$(locked "$two" other)" = "$(revision_of other)" ] || fail "not all were moved"

    echo "an update of flake.lock changes no folder's lock"
    move_on base "base, moved on"
    nix flake update --flake "path:$repo" 2> /dev/null
    before=$(cat "$one" "$two" | sha256sum)
    said=$(flake-inputs --flake "$repo" lock 2> /dev/null)
    [ -z "$said" ] && [ "$(cat "$one" "$two" | sha256sum)" = "$before" ] || fail "the locks changed with flake.lock: $said"

    echo "a name no folder declares is refused"
    if flake-inputs --flake "$repo" update nobody 2> refused; then fail "an unknown name was taken"; fi
    grep -q "no folder declares an input named nobody" refused || fail "refused with: $(cat refused)"

    touch $out
  ''
