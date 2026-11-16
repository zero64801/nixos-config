# shellcheck shell=bash
# The menu nixvirt-snapshot opens when run with no arguments on a terminal. It only reads. It picks a domain, an
# action and a snapshot by single keys, then runs the command line a user would have typed, so every check and
# confirmation stays with that command and a key touch still names the exact action.

menu_quit() {
  echo
  echo "nothing was changed."
  exit 0
}

# One keypress into $key. Enter gives an empty key. q, Escape and a closed terminal quit.
menu_key() {
  IFS= read -rsn1 key || key=q
  case "$key" in
    q|$'\e') menu_quit ;;
  esac
}

# The number picked from a list of $2 entries into $picked. Up to nine entries take one key, and Enter takes $3 when given.
menu_pick() {
  local prompt=$1 count=$2 default=${3:-}
  while :; do
    printf '%s' "$prompt"
    if [ "$count" -le 9 ]; then
      menu_key
      echo "$key"
    else
      IFS= read -r key || menu_quit
      [ "$key" != q ] || menu_quit
    fi
    picked=${key:-$default}
    if [[ $picked =~ ^[1-9][0-9]*$ ]] && [ "$picked" -le "$count" ]; then return 0; fi
  done
}

# The snapshots from $1 down to the oldest, which is the chain every action works on.
menu_chain() {
  local name=$1 left=64
  while [ -n "$name" ] && [ "$left" -gt 0 ]; do
    printf '%s\n' "$name"
    left=$((left - 1))
    name=$(virsh snapshot-dumpxml "$dom" "$name" 2>/dev/null \
      | xmlstarlet sel -t -v "/domainsnapshot/parent/name" 2>/dev/null || true)
  done
}

# Why action $1 cannot run on $dom now, empty when it can. The command checks again, this only keeps dead ends off the menu.
menu_blocked() {
  case "$state" in
    running|"shut off") ;;
    *) echo "needs the VM running or shut off"; return ;;
  esac
  [ "$1" != create ] || return 0
  if [ -z "$cur" ]; then echo "no snapshot yet"; return; fi
  if [ "$1" = revert ] && [ "$state" != "shut off" ]; then echo "needs the VM shut off"; fi
}

menu() {
  local domains=() chain=() argv=() extra=() width=0 count shown entry letter action why allowed lower more name target line i
  local -A does question
  mapfile -t domains < <(virsh list --all --name | grep . || true)
  if [ "${#domains[@]}" -eq 0 ]; then
    echo "libvirt lists no domains" >&2
    exit 1
  fi
  for dom in "${domains[@]}"; do
    [ "${#dom}" -le "$width" ] || width=${#dom}
  done

  while :; do
    echo
    i=0
    for dom in "${domains[@]}"; do
      i=$((i + 1))
      state=$(virsh domstate "$dom" 2>/dev/null || true)
      cur=$(virsh snapshot-current --name "$dom" 2>/dev/null || true)
      count=$(virsh snapshot-list "$dom" --name 2>/dev/null | grep -c . || true)
      shown=${cur:-no snapshot}
      [ "$count" -le 1 ] || shown="$cur ($count snapshots)"
      printf '  %d  %-*s  %-9s  %s\n' "$i" "$width" "$dom" "${state:-unknown}" "$shown"
    done
    menu_pick "domain (q quits): " "${#domains[@]}"
    dom=${domains[picked - 1]}

    state=$(virsh domstate "$dom" 2>/dev/null || true)
    cur=$(virsh snapshot-current --name "$dom" 2>/dev/null || true)
    echo
    list_domain
    echo
    does=(
      [rotate]="keep the changes: merge down into the base, then take the snapshot again"
      [revert]="drop the changes: go back to a snapshot"
      [create]="take a new snapshot on top"
      [commit]="merge snapshots down into their base and remove them"
      [delete]="remove one snapshot and keep the current data"
    )
    allowed=""
    for entry in r:rotate v:revert c:create m:commit d:delete; do
      letter=${entry%%:*}
      action=${entry#*:}
      why=$(menu_blocked "$action")
      if [ -n "$why" ]; then
        printf '  \e[2m-  %-7s %s\e[0m\n' "$action" "$why"
      else
        printf '  %s  %-7s %s\n' "$letter" "$action" "${does[$action]}"
        allowed+=$letter
      fi
    done
    echo "  b  back, q quits, a capital letter lets you add options before it runs"
    while :; do
      printf 'action: '
      menu_key
      echo "$key"
      [ "$key" != b ] || continue 2
      lower=${key,,}
      if [ -n "$lower" ] && [[ $allowed == *"$lower"* ]]; then break; fi
    done
    more=0
    [ "$key" = "$lower" ] || more=1
    case "$lower" in
      r) action=rotate ;;
      v) action=revert ;;
      c) action=create ;;
      m) action=commit ;;
      d) action=delete ;;
    esac

    if [ "$action" = create ]; then
      printf 'name (Enter for a time stamped one): '
      IFS= read -r name || menu_quit
      argv=(create "$dom")
      [ -z "$name" ] || argv+=("$name")
    else
      mapfile -t chain < <(menu_chain "$cur")
      target=$cur
      if [ "${#chain[@]}" -gt 1 ]; then
        question=(
          [rotate]="rotate which snapshot? Newer ones are merged into it."
          [revert]="revert to which snapshot? Everything newer is discarded."
          [commit]="merge down through which snapshot?"
          [delete]="delete which snapshot?"
        )
        echo
        echo "${question[$action]}"
        for i in "${!chain[@]}"; do
          printf '  %d  %s\n' "$((i + 1))" "${chain[i]}"
        done
        menu_pick "snapshot (Enter for $cur, the current one): " "${#chain[@]}" 1
        target=${chain[picked - 1]}
      fi
      if [ "$action" = commit ]; then
        argv=(commit --to "$target" "$dom")
      else
        argv=("$action" "$dom" "$target")
      fi
    fi

    if [ "$more" -eq 1 ]; then
      printf 'nixvirt-snapshot %s ' "${argv[*]}"
      IFS= read -r line || menu_quit
      # Split on blanks, which no option or name here holds.
      read -ra extra <<<"$line"
      argv+=("${extra[@]}")
    fi
    break
  done

  echo
  if [ "$(id -u)" -eq 0 ]; then
    echo "-> nixvirt-snapshot ${argv[*]}"
    exec "$0" "${argv[@]}"
  fi
  echo "-> sudo nixvirt-snapshot ${argv[*]}"
  exec sudo nixvirt-snapshot "${argv[@]}"
}
