{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption concatStringsSep;
  inherit (lib.types) bool enum;

  cfg = config.nyx.virtualisation.gpuSwitch;
  vfioCfg = config.nyx.virtualisation.desktop.vfio;

  /*
  nvidia-smi, only when an nvidia host driver is actually configured. Used to
  enable persistence mode after binding the host driver: Blackwell/50-series
  cards spin fans at idle unless a driver keeps the GPU initialized, and
  persistence mode provides exactly that with no client attached. The flag
  lives with the loaded module, so rmmod (on the way to vfio) wipes it
  automatically — no conflict with passthrough. (lib.optionalString is lazy,
  so non-nvidia hosts never pull the driver package into their closure.)
  */
  nvidiaEnabled = lib.elem "nvidia" config.services.xserver.videoDrivers;
  nvidiaSmi = lib.optionalString nvidiaEnabled "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";

  # Shared by the CLI and the libvirt hook; both need coreutils on PATH.
  pciHelpers = ''
    normalize_addr() {
      case "$1" in
        *:*:*.*) echo "$1" ;;
        *)       echo "0000:$1" ;;
      esac
    }

    current_driver() {
      local link="/sys/bus/pci/devices/$1/driver" path
      if [ -L "$link" ]; then
        path="$(readlink "$link")"
        echo "''${path##*/}"
      else
        echo "none"
      fi
    }
  '';

  gpuSwitch = pkgs.writeShellApplication {
    name = "gpu-switch";

    runtimeInputs = with pkgs; [
      /*
      unbind_device runs `timeout 5 bash -c …`; without it the per-device
      sysfs unbind fails and falls back to rmmod, which can't detach the
      shared snd_hda_intel audio function.
      */
      bash
      kmod
      pciutils
      libvirt
      coreutils
      gnugrep
      gnused # show_status pipes lspci through sed
      gawk
      psmisc
    ];

    text = ''
      set -euo pipefail

      PCI_ADDRS=(${concatStringsSep " " (map (a: "\"${a}\"") vfioCfg.pciAddresses)})
      DEFAULT_MODE="${cfg.defaultMode}"
      NVIDIA_SMI="${nvidiaSmi}"

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

      ${pciHelpers}

      read_sys() {
        cat "$1" 2>/dev/null || echo ""
      }

      # True while any PCI device is still bound to the driver (checked after the targets unbind, so hits mean a non-target card, e.g. a second same-vendor GPU or an APU).
      driver_has_bound_devices() {
        local dev
        for dev in /sys/bus/pci/drivers/"$1"/????:??:??.?; do
          [ -e "$dev" ] && return 0
        done
        return 1
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
        # Userspace may be holding the device (pipewire on HDMI audio, nvidia during VRAM teardown).
        # Use a timeout so we don't wedge, and fall back to module removal.
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

      # KWin/Wayland compositors hold DRM refs on cards they enumerate, which wedges PCI unbind in an uninterruptible kernel wait.
      # Workaround from Bensikrac/VFIO-Nvidia-dynamic-unbind and Level1Techs threads: a fake `remove` uevent makes KWin release its FDs on the card and render node, so the unbind completes.
      # Then evict remaining userspace: holders of each target's own DRM nodes (amdgpu or nvidia_drm targets), plus /dev/nvidia* leftovers when an nvidia card is leaving.
      release_compositor_holds() {
        local addr card node has_nvidia=0
        for addr in "$@"; do
          if [ -d "/sys/bus/pci/devices/$addr/drm" ]; then
            for card in /sys/bus/pci/devices/"$addr"/drm/card*; do
              if [ -e "$card/uevent" ]; then
                echo "  notify remove $(basename "$card") ($addr)"
                echo -n remove > "$card/uevent" 2>/dev/null || true
              fi
            done
          fi
          if [ "$(read_sys "/sys/bus/pci/devices/$addr/vendor")" = "0x10de" ]; then
            has_nvidia=1
          fi
        done
        sleep 0.5
        for addr in "$@"; do
          for node in /dev/dri/by-path/pci-"$addr"-*; do
            if [ -e "$node" ]; then
              fuser -k "$node" >/dev/null 2>&1 || true
            fi
          done
        done
        if [ "$has_nvidia" = 1 ]; then
          local dev
          for dev in /dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-modeset; do
            if [ -e "$dev" ]; then
              fuser -k "$dev" >/dev/null 2>&1 || true
            fi
          done
        fi
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
        local has_nvidia=0 has_amdgpu=0
        for addr in "''${addrs[@]}"; do
          case "$(read_sys "/sys/bus/pci/devices/$addr/vendor")" in
            0x10de) has_nvidia=1 ;;
            0x1002)
              case "$(read_sys "/sys/bus/pci/devices/$addr/class")" in
                0x0403*) ;;
                *) has_amdgpu=1 ;;
              esac ;;
          esac
        done
        # Refuse to silently SIGKILL CUDA work (llama.cpp serving etc). The
        # eviction below is indiscriminate; make the caller decide.
        if [ "$has_nvidia" = 1 ] && [ -n "$NVIDIA_SMI" ] && [ "''${GPU_SWITCH_FORCE:-0}" != 1 ]; then
          compute_apps="$("$NVIDIA_SMI" --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null || true)"
          if [ -n "$compute_apps" ]; then
            echo "gpu-switch: compute workloads hold the GPU and would be killed:" >&2
            echo "$compute_apps" >&2
            echo "gpu-switch: stop them first, or rerun with GPU_SWITCH_FORCE=1 to evict anyway." >&2
            exit 1
          fi
        fi
        # Drop persistence mode first so the nvidia driver de-initializes the GPU; otherwise the unbind below burns its 5s timeout before falling back to rmmod.
        if [ "$has_nvidia" = 1 ] && [ -n "$NVIDIA_SMI" ] && lsmod | awk '{print $1}' | grep -qx nvidia; then
          "$NVIDIA_SMI" -pm 0 >/dev/null 2>&1 || true
        fi
        release_compositor_holds "''${addrs[@]}"
        for addr in "''${addrs[@]}"; do
          unbind_device "$addr"
        done
        # Unload a GPU stack only when none of its devices remain bound — a same-vendor card still driving the host (second GPU, APU) keeps its driver.
        # The unload matters because both stacks can leave VRAM/firmware state after unbind that keeps vfio-pci from reclaiming the card.
        # snd_hda_intel is never rmmod'd (shared with motherboard audio); driver_override pins the target to vfio-pci regardless.
        if [ "$has_nvidia" = 1 ] && ! driver_has_bound_devices nvidia; then
          unload_modules "''${NVIDIA_MODULES[@]}" || true
        fi
        if [ "$has_amdgpu" = 1 ] && ! driver_has_bound_devices amdgpu; then
          unload_modules "''${AMDGPU_MODULES[@]}" || true
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
        local bound_nvidia=0
        for addr in "''${addrs[@]}"; do
          target="$(native_driver_for "$addr")"
          if [ -z "$target" ]; then
            echo "  skip   $addr (no native driver known for vendor)"
            continue
          fi
          bind_device "$addr" "$target"
          [ "$target" = "nvidia" ] && bound_nvidia=1
        done
        # Keep the (Blackwell) GPU initialized at idle so its fan stays at zero-RPM.
        # Persistence mode is the lightweight "driver attached, no client" state; it is wiped when the module unloads for vfio, so it never blocks passthrough.
        if [ "$bound_nvidia" = 1 ] && [ -n "$NVIDIA_SMI" ]; then
          echo "  enabling nvidia persistence mode (idle zero-RPM fan)"
          "$NVIDIA_SMI" -pm 1 >/dev/null 2>&1 || echo "  (nvidia-smi -pm 1 failed; fan may spin at idle)"
        fi
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

    # prepare/begin: bind the GPU to vfio-pci before the guest starts.
    # release/end: bind it back to the host driver so zero-RPM idle returns (vfio-pci leaves fans at the vBIOS default).
    case "$HOOK_NAME/$STATE_NAME" in
      prepare/begin|release/end) ;;
      *) exit 0 ;;
    esac

    PCI_ADDRS=(${concatStringsSep " " (map (a: "\"${a}\"") vfioCfg.pciAddresses)})
    GPU_SWITCH="${lib.getExe gpuSwitch}"
    AWK="${lib.getExe pkgs.gawk}"
    LOGGER="${lib.getExe' pkgs.util-linux "logger"}"
    export PATH="${lib.makeBinPath [ pkgs.coreutils ]}:$PATH"

    # Record which phase fired — libvirt only surfaces hook output on non-zero exit, so successful release runs were previously invisible.
    # Observable via `journalctl -t gpu-vfio-hook`.
    "$LOGGER" -t gpu-vfio-hook "phase=$HOOK_NAME/$STATE_NAME guest=$GUEST_NAME"

    ${pciHelpers}

    hex_fixed() {
      local width="$1" value="''${2#0x}"
      printf "0x%0''${width}x" "0x$value"
    }

    hex_function() {
      local value="''${1#0x}"
      printf "0x%x" "0x$value"
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

    # True if ANY configured device is still on vfio-pci.
    # Used to verify the host-restore actually released the GPU — a leftover vfio-pci bind on the VGA function is what leaves the fan spinning.
    any_device_vfio() {
      local addr
      for addr in "''${PCI_ADDRS[@]}"; do
        addr="$(normalize_addr "$addr")"
        if [ "$(current_driver "$addr")" = "vfio-pci" ]; then
          return 0
        fi
      done
      return 1
    }

    DOMAIN_XML="$(cat || true)"
    if ! [[ "$DOMAIN_XML" =~ [^[:space:]] ]]; then
      "$LOGGER" -t gpu-vfio-hook "no domain XML for $GUEST_NAME ($HOOK_NAME/$STATE_NAME); skipping"
      echo "gpu-vfio-hook: no domain XML for $GUEST_NAME; skipping GPU ownership check" >&2
      exit 0
    fi

    if ! domain_uses_configured_gpu; then
      "$LOGGER" -t gpu-vfio-hook "$GUEST_NAME does not use the configured GPU ($HOOK_NAME/$STATE_NAME); skipping"
      exit 0
    fi

    case "$HOOK_NAME/$STATE_NAME" in
      prepare/begin)
        if all_devices_vfio; then
          exit 0
        fi
        echo "gpu-vfio-hook: $GUEST_NAME uses the configured passthrough GPU; switching it to vfio-pci" >&2
        GPU_SWITCH_SKIP_VM_CHECK=1 "$GPU_SWITCH" vfio
        if ! all_devices_vfio; then
          echo "gpu-vfio-hook: failed to bind all configured passthrough devices to vfio-pci" >&2
          exit 1
        fi
        ;;
      release/end)
        # The guest has stopped; reclaim the card for the host driver so the fan returns to zero-RPM.
        # We skip gpu-switch's any-vm-running guard: the just-stopped domain can still transiently register as running, which made `gpu-switch host` bail out.
        # The domain_uses check above already confirmed THIS guest owned the GPU, and only one VM can hold it, so skipping is safe.
        # Non-fatal: a stop-phase hook can't undo the shutdown, so on failure we warn rather than error; output is teed to the journal.
        "$LOGGER" -t gpu-vfio-hook "release/end: restoring host driver for $GUEST_NAME"
        echo "gpu-vfio-hook: $GUEST_NAME released the passthrough GPU; restoring host driver" >&2
        GPU_SWITCH_SKIP_VM_CHECK=1 "$GPU_SWITCH" host 2>&1 | "$LOGGER" -t gpu-vfio-hook || true
        if any_device_vfio; then
          "$LOGGER" -t gpu-vfio-hook "WARNING: GPU still on vfio-pci after host restore"
          echo "gpu-vfio-hook: WARNING: GPU still bound to vfio-pci after host restore;" \
               "fan may keep spinning. If no other VM is using it, run" \
               "'sudo gpu-switch host' to retry." >&2
        else
          "$LOGGER" -t gpu-vfio-hook "GPU returned to host driver"
          echo "gpu-vfio-hook: GPU returned to host driver." >&2
        fi
        ;;
    esac
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

    /*
    When the GPU rests on the host nvidia driver at boot (defaultMode=host),
    it binds via normal driver autoprobe — not through `gpu-switch host` — so
    nothing sets persistence mode and the Blackwell idle fan would spin. This
    oneshot enables it at boot. It is a no-op if the card is on vfio (nvidia-
    smi finds no device), so it never interferes with passthrough boots.
    */
    (mkIf (nvidiaEnabled && cfg.defaultMode == "host") {
      systemd.services.nvidia-idle-persistence = {
        description = "Enable NVIDIA persistence mode so the idle GPU keeps zero-RPM fan (Blackwell idle-fan workaround)";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Retry to ride out boot-time driver/device-node settling.
          ExecStart = pkgs.writeShellScript "nvidia-idle-persistence" ''
            for _ in 1 2 3 4 5; do
              if ${nvidiaSmi} -pm 1 >/dev/null 2>&1; then
                echo "nvidia persistence mode enabled"
                exit 0
              fi
              sleep 2
            done
            echo "nvidia-idle-persistence: GPU not on nvidia (likely vfio); skipping" >&2
            exit 0
          '';
        };
      };
    })
  ]);
}
