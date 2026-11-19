# nix build --no-link -L .#tests.pinning.pin
# pin on a made up repository with git repositories for inputs and no network: it sees the inputs of flake.nix and of the folders alike, and an update leaves a frozen one where it is.
{
  host,
}:

let
  inherit (host) pkgs;
  inherit ((host.evaluate { config.my.pinning.enable = true; }).config) nix my;
in
pkgs.runCommand "pin-test"
  {
    nativeBuildInputs = [
      my.pinning.package
      pkgs.util.flakeInputs
      nix.package
      pkgs.git
      pkgs.jq
    ];
  }
  ''
    source ${../../../core/inputs/_tests/_made-up-repo.sh}
    # No terminal to colour for, so that what pin prints can be read as it stands.
    export TERM=dumb
    export MY_FLAKE_PATH=$repo MY_PINS_FILE=$repo/pins.json
    one=$repo/things/one/_inputs.lock
    two=$repo/things/two/_inputs.lock
    flake-inputs --flake "$repo" lock
    git -C "$repo" add -A

    echo "the status lists the inputs of flake.nix and of the folders"
    pin status > status
    for name in base dep mate other; do
      grep -q "$name .*tracking" status || fail "$name is missing from the status: $(cat status)"
    done

    echo "a frozen input is shown as such and holds the revision it has"
    pin freeze dep --reason "kept as it is"
    pin status > status
    grep -q "dep .*frozen" status || fail "dep is not shown as frozen: $(cat status)"
    frozen=$(locked "$one" dep)
    [ "$(jq -r .pins.dep.rev "$repo/pins.json")" = "$frozen" ] || fail "the pin does not hold the locked revision"

    echo "an update moves what flake.nix has and what the folders have, and leaves the frozen one"
    for name in base dep mate other; do move_on "$name" "$name, moved on"; done
    pin update
    [ "$(locked "$repo/flake.lock" base)" = "$(revision_of base)" ] || fail "base was not moved"
    [ "$(locked "$two" other)" = "$(revision_of other)" ] || fail "other was not moved"
    [ "$(locked "$two" mate)" = "$(revision_of mate)" ] || fail "mate was not moved"
    [ "$(locked "$one" dep)" = "$frozen" ] || fail "the frozen dep was moved"
    pin check > check || fail "the check found a pin out of step: $(cat check)"
    grep -q "dep (frozen" check || fail "the check does not name dep: $(cat check)"

    echo "a frozen input is skipped when named, unless forced"
    pin update dep > skipped
    grep -q "Skipping.*dep" skipped || fail "the update did not say it skipped dep: $(cat skipped)"
    [ "$(locked "$one" dep)" = "$frozen" ] || fail "the frozen dep was moved when named"
    pin update dep --force
    [ "$(locked "$one" dep)" = "$(revision_of dep)" ] || fail "the forced update did not move dep"

    echo "an input that is no longer frozen moves with the next update"
    pin unpin dep
    move_on dep "dep, moved on again"
    pin update
    [ "$(locked "$one" dep)" = "$(revision_of dep)" ] || fail "dep was not moved after it was unpinned"

    touch $out
  ''
