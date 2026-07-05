#!/usr/bin/env bash

set -euo pipefail

GUEST_NAME="$1"
HOOK_NAME="$2"
STATE_NAME="$3"

# Size the 2MiB hugepage pool dynamically per domain so no host RAM is
# reserved while VMs are off. Acts only on domains whose XML requests
# <hugepages/>. Runs before the per-domain hooks (10- prefix ordering).
HP_DIR="${HUGEPAGES_DIR:-/sys/kernel/mm/hugepages/hugepages-2048kB}"

XML=$(cat || true)

grep -q '<hugepages' <<<"$XML" || exit 0

mem_kib=$(sed -n "s/.*<memory unit=.KiB.>\([0-9]\{1,\}\).*/\1/p" <<<"$XML" | head -n1)
[[ -n "$mem_kib" ]] || exit 0
pages=$(( (mem_kib + 2047) / 2048 ))

nr() { cat "$HP_DIR/nr_hugepages"; }

case "$HOOK_NAME/$STATE_NAME" in
  prepare/begin)
    before=$(nr)
    want=$(( before + pages ))
    echo "$want" > "$HP_DIR/nr_hugepages"
    if [[ "$(nr)" -lt "$want" ]]; then
      echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
      echo "$want" > "$HP_DIR/nr_hugepages"
    fi
    if [[ "$(nr)" -lt "$want" ]]; then
      got=$(nr)
      echo "$before" > "$HP_DIR/nr_hugepages"
      echo "hugepages: only $got of $want 2MiB pages available for $GUEST_NAME, aborting start" >&2
      exit 1
    fi
    ;;
  release/end)
    now=$(nr)
    new=$(( now - pages ))
    if (( new < 0 )); then new=0; fi
    echo "$new" > "$HP_DIR/nr_hugepages"
    ;;
esac
