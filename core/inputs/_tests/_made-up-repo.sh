# A made up repository whose inputs are git repositories beside it, for trying the tools that lock inputs inside a build, with no network.
# It leaves $repo, with flake.nix and two folders that declare inputs, and the functions below to move a source on and to look at a lock.

export HOME=$TMPDIR/home
export NIX_STORE_DIR=$TMPDIR/store NIX_STATE_DIR=$TMPDIR/state NIX_LOCALSTATE_DIR=$TMPDIR/var NIX_LOG_DIR=$TMPDIR/log NIX_CONF_DIR=$TMPDIR/etc
# A store of its own, used directly: there is no daemon for it to ask.
export NIX_REMOTE=local
export NIX_CONFIG="experimental-features = nix-command flakes"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org
mkdir -p "$HOME" "$NIX_CONF_DIR"

sources=$TMPDIR/sources
repo=$TMPDIR/repo

fail() {
  echo "FAILED: $*" >&2
  exit 1
}

# A source's flake says one thing, in the file said, and what it saw of its inputs.
source_flake() {
  local name=$1 inputs=$2 outputs=$3
  mkdir -p "$sources/$name"
  echo "$name as it was first" > "$sources/$name/said"
  cat > "$sources/$name/flake.nix" <<END
{
  $inputs
  outputs = $outputs;
}
END
  git -C "$sources/$name" init --quiet --initial-branch=main
  git -C "$sources/$name" add -A
  git -C "$sources/$name" commit --quiet -m first
}

# move_on NAME WORDS: the source gets a new commit, in which it says WORDS.
move_on() {
  echo "$2" > "$sources/$1/said"
  git -C "$sources/$1" commit --quiet -a -m "$2"
}

revision_of() {
  git -C "$sources/$1" rev-parse HEAD
}

# locked LOCK NAME: the revision a lock holds for one of its root's inputs.
locked() {
  jq -r --arg name "$2" '.nodes[.nodes[.root].inputs[$name]].locked.rev // "none"' "$1"
}

says='builtins.readFile ./said'
source_flake base "" "_: { said = $says; }"
source_flake base-of-its-own "" "_: { said = $says; }"
source_flake dep "inputs.base.url = \"git+file://$sources/base-of-its-own\";" "{ self, base }: { said = $says; saw = base.said; }"
source_flake other "" "_: { said = $says; }"
source_flake mate "" "_: { said = $says; }"

mkdir -p "$repo/things/one" "$repo/things/two"
cat > "$repo/flake.nix" <<END
{
  inputs.base.url = "git+file://$sources/base";
  outputs = _: { };
}
END
cat > "$repo/things/one/_inputs.nix" <<END
{
  dep = {
    url = "git+file://$sources/dep";
    inputs.base.follows = "base";
  };
}
END
cat > "$repo/things/two/_inputs.nix" <<END
{
  other.url = "git+file://$sources/other";
  mate.url = "git+file://$sources/mate";
}
END
nix flake lock "path:$repo" 2> /dev/null
git -C "$repo" init --quiet --initial-branch=main
git -C "$repo" add -A
