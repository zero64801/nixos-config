#!/usr/bin/env bash

set -euo pipefail

GUEST_NAME="$1"
HOOK_NAME="$2"
STATE_NAME="$3"

[[ "$GUEST_NAME" == "win11-x3d" ]] || exit 0

# Isolate CCD0 (host CPUs 0-7 + SMT siblings 16-23, the X3D V-Cache CCD) for the win11-x3d VM.
# On VM start: shrink host cgroup slices to CCD1 only (8-15 + SMT 24-31) so nothing competes with the pinned vCPUs.
# On VM stop: restore host access to all 32 logical CPUs.
ALL_CPUS="0-31"
HOST_CPUS="8-15,24-31"

apply() {
  local cpus="$1"
  systemctl set-property --runtime -- system.slice AllowedCPUs="$cpus"
  systemctl set-property --runtime -- user.slice   AllowedCPUs="$cpus"
  systemctl set-property --runtime -- init.scope   AllowedCPUs="$cpus"
}

# Per-core EPP: only flip CCD0 (VM cores) to performance.
# Leaves CCD1 (host) on dynamic amd-pstate-epp.
VM_CPUS_LIST="0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23"
set_epp() {
  local pref="$1"
  for c in $VM_CPUS_LIST; do
    echo "$pref" > "/sys/devices/system/cpu/cpu$c/cpufreq/energy_performance_preference"
  done
}

case "$HOOK_NAME/$STATE_NAME" in
  prepare/begin)
    apply "$HOST_CPUS"
    set_epp performance
    ;;
  release/end)
    apply "$ALL_CPUS"
    set_epp balance_performance
    ;;
esac
