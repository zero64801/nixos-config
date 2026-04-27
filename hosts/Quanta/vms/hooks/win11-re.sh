#!/usr/bin/env bash
# Isolate CCD1 (host CPUs 8-15 + SMT siblings 24-31) for the win11-re VM.
# When the VM starts: shrink host cgroup slices to CCD0 only (0-7 + 16-23),
# so nothing on the host competes with the pinned vCPU threads.
# When the VM stops: restore host access to all 32 logical CPUs.

set -euo pipefail

GUEST_NAME="$1"
HOOK_NAME="$2"
STATE_NAME="$3"

[[ "$GUEST_NAME" == "win11-re" ]] || exit 0

ALL_CPUS="0-31"
HOST_CPUS="0-7,16-23"

apply() {
  local cpus="$1"
  systemctl set-property --runtime -- system.slice AllowedCPUs="$cpus"
  systemctl set-property --runtime -- user.slice   AllowedCPUs="$cpus"
  systemctl set-property --runtime -- init.scope   AllowedCPUs="$cpus"
}

case "$HOOK_NAME/$STATE_NAME" in
  prepare/begin)
    apply "$HOST_CPUS"
    ;;
  release/end)
    apply "$ALL_CPUS"
    ;;
esac
