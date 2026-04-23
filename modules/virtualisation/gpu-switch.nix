{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption concatStringsSep;
  inherit (lib.types) enum;

  cfg = config.nyx.virtualisation.gpuSwitch;
  vfioCfg = config.nyx.virtualisation.desktop.vfio;

  gpuSwitch = pkgs.writeShellApplication {
    name = "gpu-switch";

    runtimeInputs = with pkgs; [
      kmod
      pciutils
      libvirt
      coreutils
      gnugrep
      gawk
      psmisc
    ];

    text = ''
      set -euo pipefail

      PCI_ADDRS=(${concatStringsSep " " (map (a: "\"${a}\"") vfioCfg.pciAddresses)})
      DEFAULT_MODE="${cfg.defaultMode}"

      if [ "''${#PCI_ADDRS[@]}" -eq 0 ]; then
        echo "gpu-switch: no PCI addresses configured (nyx.virtualisation.desktop.vfio.pciAddresses)" >&2
        exit 1
      fi

      NVIDIA_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
      AMDGPU_MODULES=(amdgpu)
      VFIO_MODULES=(vfio_pci vfio_iommu_type1 vfio)

      require_root() {
        if [ "$(id -u)" -ne 0 ]; then
          echo "gpu-switch: must be run as root (use sudo)" >&2
          exit 1
        fi
      }

      normalize_addr() {
        case "$1" in
          0000:*) echo "$1" ;;
          *)      echo "0000:$1" ;;
        esac
      }

      read_sys() {
        cat "$1" 2>/dev/null || echo ""
      }

      current_driver() {
        local addr="$1"
        if [ -L "/sys/bus/pci/devices/$addr/driver" ]; then
          basename "$(readlink "/sys/bus/pci/devices/$addr/driver")"
        else
          echo "none"
        fi
      }

      # Returns the native host driver to bind for a given PCI device.
      # Audio function is class 0x0403xx; GPU is 0x0300xx / 0x0302xx.
      native_driver_for() {
        local addr="$1" vendor class
        vendor="$(read_sys "/sys/bus/pci/devices/$addr/vendor")"
        class="$(read_sys "/sys/bus/pci/devices/$addr/class")"
        case "$class" in
          0x0403*) echo "snd_hda_intel" ;;
          *)
            case "$vendor" in
              0x10de) echo "nvidia" ;;
              0x1002) echo "amdgpu" ;;
              *)      echo "" ;;
            esac ;;
        esac
      }

      collect_native_modules() {
        local need_nvidia=0 need_amdgpu=0 need_audio=0
        local addr vendor class
        for addr in "$@"; do
          vendor="$(read_sys "/sys/bus/pci/devices/$addr/vendor")"
          class="$(read_sys "/sys/bus/pci/devices/$addr/class")"
          case "$class" in
            0x0403*) need_audio=1 ;;
            *)
              case "$vendor" in
                0x10de) need_nvidia=1 ;;
                0x1002) need_amdgpu=1 ;;
              esac ;;
          esac
        done
        [ "$need_nvidia" -eq 1 ] && printf '%s\n' "''${NVIDIA_MODULES[@]}"
        [ "$need_amdgpu" -eq 1 ] && printf '%s\n' "''${AMDGPU_MODULES[@]}"
        [ "$need_audio"  -eq 1 ] && printf '%s\n' "snd_hda_intel"
        return 0
      }

      any_vm_running() {
        local out
        out="$(virsh list --state-running --name 2>/dev/null || true)"
        [ -n "$(echo "$out" | tr -d '[:space:]')" ]
      }

      unbind_device() {
        local addr="$1" drv
        drv="$(current_driver "$addr")"
        if [ "$drv" = "none" ]; then
          return
        fi
        echo "  unbind $addr (was $drv)"
        # Userspace may be holding the device (pipewire on HDMI audio, or
        # the nvidia driver during VRAM teardown). Use a timeout so we
        # don't wedge, and fall back to module removal.
        if ! timeout 5 bash -c "echo '$addr' > /sys/bus/pci/devices/$addr/driver/unbind"; then
          echo "  unbind $addr timed out — forcing via rmmod $drv"
          case "$drv" in
            snd_hda_intel)
              modprobe -r snd_hda_intel 2>/dev/null || true
              ;;
            nvidia|nvidia_drm|nvidia_modeset)
              modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true
              ;;
            *)
              modprobe -r "$drv" 2>/dev/null || true
              ;;
          esac
        fi
      }

      bind_device() {
        local addr="$1" target="$2"
        echo "$target" > "/sys/bus/pci/devices/$addr/driver_override"
        echo "  bind   $addr -> $target"
        echo "$addr" > /sys/bus/pci/drivers_probe || true
      }

      unload_modules() {
        local m
        for m in "$@"; do
          if lsmod | awk '{print $1}' | grep -qx "$m"; then
            echo "  rmmod $m"
            if ! modprobe -r "$m"; then
              echo "gpu-switch: failed to remove module $m (in use?)" >&2
              return 1
            fi
          fi
        done
      }

      load_modules() {
        local m
        for m in "$@"; do
          echo "  modprobe $m"
          if ! modprobe "$m" 2>/dev/null; then
            echo "    (skipped: blacklisted or unavailable)"
          fi
        done
      }

      normalized_addrs() {
        local a
        for a in "''${PCI_ADDRS[@]}"; do
          normalize_addr "$a"
        done
      }

      # KWin/Wayland compositors hold DRM refs on cards they enumerate,
      # which wedges PCI unbind in an uninterruptible kernel wait. The
      # workaround used by Bensikrac/VFIO-Nvidia-dynamic-unbind and
      # various Level1Techs threads: send a fake `remove` uevent on the
      # card's sysfs node. KWin watches these and releases its FDs on
      # both the card and its associated render node, so the subsequent
      # unbind completes normally. We also kill any remaining userspace
      # holding /dev/nvidia* (nvidia-smi leftovers, persistenced, etc.).
      release_compositor_holds() {
        local addr card
        for addr in "$@"; do
          if [ -d "/sys/bus/pci/devices/$addr/drm" ]; then
            for card in /sys/bus/pci/devices/"$addr"/drm/card*; do
              if [ -e "$card/uevent" ]; then
                echo "  notify remove $(basename "$card") ($addr)"
                echo -n remove > "$card/uevent" 2>/dev/null || true
              fi
            done
          fi
        done
        sleep 0.5
        local dev
        for dev in /dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-modeset; do
          if [ -e "$dev" ]; then
            fuser -k "$dev" >/dev/null 2>&1 || true
          fi
        done
        sleep 0.3
      }

      switch_to_vfio() {
        echo "Switching GPU -> vfio-pci"
        if any_vm_running; then
          echo "gpu-switch: refusing to switch while a VM is running" >&2
          exit 1
        fi
        local addr
        local -a addrs
        mapfile -t addrs < <(normalized_addrs)
        release_compositor_holds "''${addrs[@]}"
        for addr in "''${addrs[@]}"; do
          unbind_device "$addr"
        done
        # Only rmmod the nvidia stack — it leaves VRAM / firmware state
        # after unbind that can keep vfio-pci from reclaiming the card.
        # Don't touch snd_hda_intel (shared with motherboard audio,
        # rmmod fails when other cards hold it) or amdgpu (almost always
        # driving the primary display). driver_override pins our target
        # to vfio-pci regardless.
        local has_nvidia=0
        for addr in "''${addrs[@]}"; do
          if [ "$(read_sys "/sys/bus/pci/devices/$addr/vendor")" = "0x10de" ]; then
            has_nvidia=1
            break
          fi
        done
        if [ "$has_nvidia" = 1 ]; then
          unload_modules "''${NVIDIA_MODULES[@]}" || true
        fi
        load_modules "''${VFIO_MODULES[@]}"
        for addr in "''${addrs[@]}"; do
          bind_device "$addr" vfio-pci
        done
        echo "done."
      }

      switch_to_host() {
        echo "Switching GPU -> host driver"
        if any_vm_running; then
          echo "gpu-switch: refusing to switch while a VM is running" >&2
          exit 1
        fi
        local addr target
        local -a addrs native_mods
        mapfile -t addrs < <(normalized_addrs)
        mapfile -t native_mods < <(collect_native_modules "''${addrs[@]}")
        for addr in "''${addrs[@]}"; do
          unbind_device "$addr"
          echo "" > "/sys/bus/pci/devices/$addr/driver_override" || true
        done
        if [ "''${#native_mods[@]}" -gt 0 ]; then
          load_modules "''${native_mods[@]}"
        fi
        for addr in "''${addrs[@]}"; do
          target="$(native_driver_for "$addr")"
          if [ -z "$target" ]; then
            echo "  skip   $addr (no native driver known for vendor)"
            continue
          fi
          bind_device "$addr" "$target"
        done
        echo "done."
      }

      show_status() {
        local addr drv target info
        echo "gpu-switch status (default mode: $DEFAULT_MODE)"
        for addr in "''${PCI_ADDRS[@]}"; do
          addr="$(normalize_addr "$addr")"
          drv="$(current_driver "$addr")"
          target="$(native_driver_for "$addr")"
          info="$(lspci -s "$addr" 2>/dev/null | sed "s|^$addr ||")"
          printf '  %s  driver=%-14s host=%-14s %s\n' "$addr" "$drv" "$target" "$info"
        done
      }

      usage() {
        cat <<EOF
      Usage: gpu-switch <vfio|host|status>

        vfio    Bind the passthrough device(s) to vfio-pci.
        host    Bind the passthrough device(s) to their native driver
                (nvidia for 10de:*, amdgpu for 1002:*, snd_hda_intel for audio).
        status  Show current and native driver for each configured PCI device.

      PCI devices managed:
        ${concatStringsSep "\n        " vfioCfg.pciAddresses}
      EOF
      }

      case "''${1:-status}" in
        vfio)           require_root; switch_to_vfio ;;
        host)           require_root; switch_to_host ;;
        status)         show_status ;;
        -h|--help|help) usage ;;
        *)              usage; exit 2 ;;
      esac
    '';
  };
in
{
  options.nyx.virtualisation.gpuSwitch = {
    enable = mkEnableOption "runtime GPU driver switching between vfio-pci and the native host driver";

    defaultMode = mkOption {
      type = enum [ "vfio" "host" ];
      default = "vfio";
      description = "Driver mode the passthrough device(s) boot into.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ gpuSwitch ];
  };
}
