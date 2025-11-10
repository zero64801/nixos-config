{ pkgs, ... }:
{
  nyx.virtualisation.desktop.hooks.win11-re = pkgs.writeShellScript "win11-re-vfio-hook.sh" ''
    #!${pkgs.bash}/bin/bash
    set -e
    set -x

    HOST_CORES="0-3,8-11"
    ALL_CORES="0-15"

    VM_NAME="$1"
    OPERATION="$2"
    SUB_OPERATION="$3"

    SYSTEMCTL="${pkgs.systemd}/bin/systemctl"

    case "$OPERATION/$SUB_OPERATION" in
    "prepare/begin")
        echo "VFIO-HOOK: Starting for $VM_NAME"
        echo "VFIO-HOOK: Isolating CPUs. Host will use cores: $HOST_CORES"
        $SYSTEMCTL set-property --runtime -- user.slice AllowedCPUs=$HOST_CORES
        $SYSTEMCTL set-property --runtime -- system.slice AllowedCPUs=$HOST_CORES
        $SYSTEMCTL set-property --runtime -- init.scope AllowedCPUs=$HOST_CORES
    ;;

    "release/end")
        echo "VFIO-HOOK: Stopping for $VM_NAME"
        echo "VFIO-HOOK: Restoring all CPU cores ($ALL_CORES) to host"
        $SYSTEMCTL set-property --runtime -- user.slice AllowedCPUs=$ALL_CORES
        $SYSTEMCTL set-property --runtime -- system.slice AllowedCPUs=$ALL_CORES
        $SYSTEMCTL set-property --runtime -- init.scope AllowedCPUs=$ALL_CORES
    ;;
    esac
  '';
}
