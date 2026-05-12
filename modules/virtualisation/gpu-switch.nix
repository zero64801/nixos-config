{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption concatStringsSep;
  inherit (lib.types) bool enum;

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
        if [ "''${GPU_SWITCH_SKIP_VM_CHECK:-0}" = "1" ]; then
          return 1
        fi
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

  libvirtGpuVfioHook = pkgs.writeShellScript "libvirt-qemu-gpu-vfio-prepare" ''
    set -euo pipefail

    GUEST_NAME="''${1:-}"
    HOOK_NAME="''${2:-}"
    STATE_NAME="''${3:-}"

    case "$HOOK_NAME/$STATE_NAME" in
      prepare/begin) ;;
      *) exit 0 ;;
    esac

    PCI_ADDRS=(${concatStringsSep " " (map (a: "\"${a}\"") vfioCfg.pciAddresses)})
    GPU_SWITCH="${lib.getExe gpuSwitch}"
    AWK="${lib.getExe pkgs.gawk}"
    CAT="${lib.getExe' pkgs.coreutils "cat"}"
    READLINK="${lib.getExe' pkgs.coreutils "readlink"}"

    normalize_addr() {
      case "$1" in
        *:*:*.*) echo "$1" ;;
        *)       echo "0000:$1" ;;
      esac
    }

    hex_fixed() {
      local width="$1" value="''${2#0x}"
      printf "0x%0''${width}x" "0x$value"
    }

    hex_function() {
      local value="''${1#0x}"
      printf "0x%x" "0x$value"
    }

    current_driver() {
      local addr="$1" driver_link driver_path
      driver_link="/sys/bus/pci/devices/$addr/driver"
      if [ -L "$driver_link" ]; then
        driver_path="$("$READLINK" "$driver_link")"
        echo "''${driver_path##*/}"
      else
        echo "none"
      fi
    }

    domain_uses_addr() {
      local addr="$1" domain rest bus slot fn
      local domain_hex bus_hex slot_hex fn_hex

      addr="$(normalize_addr "$addr")"
      domain="''${addr%%:*}"
      rest="''${addr#*:}"
      bus="''${rest%%:*}"
      rest="''${rest#*:}"
      slot="''${rest%%.*}"
      fn="''${rest#*.}"

      domain_hex="$(hex_fixed 4 "$domain")"
      bus_hex="$(hex_fixed 2 "$bus")"
      slot_hex="$(hex_fixed 2 "$slot")"
      fn_hex="$(hex_function "$fn")"

      printf '%s\n' "$DOMAIN_XML" | "$AWK" \
        -v want_domain="$domain_hex" \
        -v want_bus="$bus_hex" \
        -v want_slot="$slot_hex" \
        -v want_function="$fn_hex" '
          function attr(line, name, m) {
            if (match(line, name "=[\"\047]([^\"\047]+)[\"\047]", m)) {
              return m[1]
            }
            return ""
          }

          /<hostdev([[:space:]>]|$)/ { in_hostdev = 1 }
          in_hostdev && /<source([[:space:]>]|$)/ { in_source = 1 }
          in_hostdev && in_source && /<address[[:space:]]/ {
            domain = attr($0, "domain")
            bus = attr($0, "bus")
            slot = attr($0, "slot")
            fn = attr($0, "function")
            if (domain == want_domain && bus == want_bus && slot == want_slot && fn == want_function) {
              found = 1
            }
          }
          in_hostdev && /<\/source>/ { in_source = 0 }
          in_hostdev && /<\/hostdev>/ { in_hostdev = 0 }

          END { exit(found ? 0 : 1) }
        '
    }

    domain_uses_configured_gpu() {
      local addr
      for addr in "''${PCI_ADDRS[@]}"; do
        if domain_uses_addr "$addr"; then
          return 0
        fi
      done
      return 1
    }

    all_devices_vfio() {
      local addr
      for addr in "''${PCI_ADDRS[@]}"; do
        addr="$(normalize_addr "$addr")"
        if [ "$(current_driver "$addr")" != "vfio-pci" ]; then
          return 1
        fi
      done
      return 0
    }

    DOMAIN_XML="$("$CAT" || true)"
    if ! [[ "$DOMAIN_XML" =~ [^[:space:]] ]]; then
      echo "gpu-vfio-hook: no domain XML for $GUEST_NAME; skipping GPU ownership check" >&2
      exit 0
    fi

    if ! domain_uses_configured_gpu; then
      exit 0
    fi

    if all_devices_vfio; then
      exit 0
    fi

    echo "gpu-vfio-hook: $GUEST_NAME uses the configured passthrough GPU; switching it to vfio-pci" >&2
    GPU_SWITCH_SKIP_VM_CHECK=1 "$GPU_SWITCH" vfio

    if ! all_devices_vfio; then
      echo "gpu-vfio-hook: failed to bind all configured passthrough devices to vfio-pci" >&2
      exit 1
    fi
  '';
in
{
  options.nyx.virtualisation.gpuSwitch = {
    enable = mkEnableOption "runtime GPU driver switching between vfio-pci and the native host driver";

    defaultMode = mkOption {
      type = enum [ "vfio" "host" ];
      default = "vfio";
      description = "Driver mode the passthrough device(s) boot into.";
    };

    libvirtHook.enable = mkOption {
      type = bool;
      default = true;
      description = ''
        Install a qemu libvirt hook that automatically switches configured
        passthrough PCI devices to vfio-pci before a domain using them starts.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = [ gpuSwitch ];
    }

    (mkIf (cfg.libvirtHook.enable && vfioCfg.enable && vfioCfg.pciAddresses != [ ]) {
      virtualisation.libvirtd.hooks.qemu."00-gpu-vfio-prepare" = libvirtGpuVfioHook;
      systemd.services.libvirtd-config.restartTriggers = [ libvirtGpuVfioHook ];
    })
  ]);
}
