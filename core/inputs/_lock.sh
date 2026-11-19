usage() {
  cat <<'END'
flake-inputs [--flake DIR] COMMAND

Locks what the folders of a flake declare for themselves: a folder's _inputs.nix says what it needs,
and the _inputs.lock beside it holds the revisions. flake.lock is left alone.

  list              every such input, with its folder, revision and date
  lock [FOLDER...]  write the locks that are missing or no longer fit, and move nothing that is locked
  update [NAME...]  move the inputs named, or all of them, to what their source has now
  set NAME REF      lock NAME to REF, as github:owner/repo/REVISION, where it stays until it is updated by name
END
}

die() {
  echo "flake-inputs: $*" >&2
  exit 1
}

repo=
if [ "${1:-}" = --flake ]; then
  repo=${2:?--flake takes a folder}
  shift 2
fi
repo=$(realpath "${repo:-$(git rev-parse --show-toplevel)}")
[ -f "$repo/flake.lock" ] || die "$repo has no flake.lock"

files() {
  git -C "$repo" ls-files --cached --others --exclude-standard -- '_inputs.nix' '*/_inputs.nix' | sort -u
}

names() {
  nix eval --impure --json --expr 'file: builtins.attrNames (import file)' --apply "names: names \"$repo/$1\"" | jq -r '.[]'
}

file_of() {
  local file
  while read -r file; do
    if names "$file" | grep -qxF -- "$1"; then
      echo "$file"
      return 0
    fi
  done < <(files)
  die "no folder declares an input named $1"
}

# relock FILE lock|update [what Nix is to be told beyond that]
relock() {
  local file=$1 mode=$2 lock work
  shift 2
  lock="$repo/$(dirname "$file")/_inputs.lock"
  work=$(mktemp -d)
  nix eval --impure --raw --file "$scratch" \
    --apply "flake: flake { declared = \"$repo/$file\"; flake = \"$repo/flake.nix\"; lock = \"$repo/flake.lock\"; }" > "$work/flake.nix"

  # The lock that is kept holds no node for an input of flake.nix, so those are put back first, as flake.lock has them now.
  if [ -f "$lock" ]; then
    jq --slurpfile root "$repo/flake.lock" '
      $root[0] as $r
      | reduce ($r.nodes[$r.root].inputs | to_entries[]) as $core (.;
          (.nodes[.root].inputs[$core.key]) as $key
          | if ($key | type) == "string" then .nodes[$key] = $r.nodes[$core.value] else . end)
    ' "$lock" > "$work/flake.lock"
  fi

  case $mode in
    lock) nix flake lock "$work" "$@" ;;
    update) nix flake update --flake "$work" "$@" ;;
  esac

  jq -S --slurpfile root "$repo/flake.lock" '
    $root[0] as $r
    | reduce ($r.nodes[$r.root].inputs | keys[]) as $core (.;
        (.nodes[.root].inputs[$core]) as $key
        | if ($key | type) == "string" then del(.nodes[$key]) else . end)
  ' "$work/flake.lock" > "$work/kept"
  if ! cmp -s "$work/kept" "$lock"; then
    cp "$work/kept" "$lock"
    echo "$(dirname "$file"): lock written"
  fi
  rm -rf "$work"
}

case ${1:-} in
  list)
    while read -r file; do
      lock="$repo/$(dirname "$file")/_inputs.lock"
      while read -r name; do
        if [ -f "$lock" ]; then
          jq -r --arg name "$name" --arg folder "$(dirname "$file")" '
            .nodes[.nodes[.root].inputs[$name]].locked
            | [$name, $folder, (.rev // "-")[0:12], ((.lastModified // 0) | strftime("%Y-%m-%d"))] | @tsv' "$lock"
        else
          printf '%s\t%s\tnot locked\t-\n' "$name" "$(dirname "$file")"
        fi
      done < <(names "$file")
    done < <(files) | column -t -s "$(printf '\t')"
    ;;
  lock)
    shift
    if [ "$#" -eq 0 ]; then
      while read -r file; do relock "$file" lock; done < <(files)
    else
      for folder in "$@"; do
        folder=$(realpath --relative-to="$repo" "$folder")
        [ -f "$repo/$folder/_inputs.nix" ] || die "$folder has no _inputs.nix"
        relock "$folder/_inputs.nix" lock
      done
    fi
    ;;
  update)
    shift
    if [ "$#" -eq 0 ]; then
      while read -r file; do relock "$file" update; done < <(files)
    else
      declare -A wanted=()
      for name in "$@"; do
        file=$(file_of "$name")
        wanted[$file]+=" $name"
      done
      for file in "${!wanted[@]}"; do
        read -r -a these <<< "${wanted[$file]}"
        relock "$file" update "${these[@]}"
      done
    fi
    ;;
  set)
    [ "$#" -eq 3 ] || die "set takes a name and what to lock it to"
    relock "$(file_of "$2")" lock --override-input "$2" "$3"
    ;;
  "" | help | --help | -h)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
