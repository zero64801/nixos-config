{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.nyx.virtualisation.desktop.gpuSwitch;

  gpuSwitchScript = pkgs.writeShellScriptBin "gpu-switch" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color

    # Configuration from NixOS
    PCI_ADDRESSES=(${concatStringsSep " " (map (addr: ''"${addr}"'') cfg.pciAddresses)})
    DEVICE_IDS=(${concatStringsSep " " (map (id: ''"${id}"'') cfg.deviceIds)})

    log_info() {
      echo -e "''${GREEN}[INFO]''${NC} $1"
    }

    log_warn() {
      echo -e "''${YELLOW}[WARN]''${NC} $1"
    }

    log_error() {
      echo -e "''${RED}[ERROR]''${NC} $1"
    }

    check_root() {
      if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
      fi
    }

    get_current_driver() {
      local addr="$1"
      local full_addr="0000:$addr"
      local driver_path="/sys/bus/pci/devices/$full_addr/driver"

      if [ -L "$driver_path" ]; then
        basename "$(readlink "$driver_path")"
      else
        echo "none"
      fi
    }

    unbind_driver() {
      local addr="$1"
      local full_addr="0000:$addr"
      local driver=$(get_current_driver "$addr")

      if [ "$driver" != "none" ]; then
        log_info "Unbinding $addr from $driver"
        echo "$full_addr" > "/sys/bus/pci/drivers/$driver/unbind" 2>/dev/null || true
        sleep 0.5
      else
        log_info "Device $addr is not bound to any driver"
      fi
    }

    bind_driver() {
      local addr="$1"
      local driver="$2"
      local full_addr="0000:$addr"

      log_info "Binding $addr to $driver"

      # Check if device exists in sysfs
      if [ ! -d "/sys/bus/pci/devices/$full_addr" ]; then
        log_warn "Device $full_addr not found in sysfs, triggering PCI rescan..."
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
        sleep 1
        if [ ! -d "/sys/bus/pci/devices/$full_addr" ]; then
          log_error "Device $full_addr still not found after rescan"
          return 1
        fi
      fi

      # Set driver override for vfio-pci
      if [ "$driver" = "vfio-pci" ]; then
        echo "vfio-pci" > "/sys/bus/pci/devices/$full_addr/driver_override" 2>/dev/null || true
      else
        echo "" > "/sys/bus/pci/devices/$full_addr/driver_override" 2>/dev/null || true
      fi

      # Try to bind to driver
      if [ -d "/sys/bus/pci/drivers/$driver" ]; then
        echo "$full_addr" > "/sys/bus/pci/drivers/$driver/bind" 2>/dev/null || {
          echo "$full_addr" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        }
      else
        log_warn "Driver $driver not loaded, triggering probe"
        echo "$full_addr" > /sys/bus/pci/drivers_probe 2>/dev/null || true
      fi

      sleep 0.5
    }

    load_nvidia_modules() {
      log_info "Loading NVIDIA modules..."
      ${pkgs.kmod}/bin/modprobe nvidia 2>/dev/null || true
      ${pkgs.kmod}/bin/modprobe nvidia_modeset 2>/dev/null || true
      ${pkgs.kmod}/bin/modprobe nvidia_uvm 2>/dev/null || true
      ${pkgs.kmod}/bin/modprobe nvidia_drm 2>/dev/null || true
    }

    unload_nvidia_modules() {
      log_info "Unloading NVIDIA modules..."

      ${pkgs.kmod}/bin/rmmod nvidia_drm 2>/dev/null || true
      ${pkgs.kmod}/bin/rmmod nvidia_uvm 2>/dev/null || true
      ${pkgs.kmod}/bin/rmmod nvidia_modeset 2>/dev/null || true
      ${pkgs.kmod}/bin/rmmod nvidia 2>/dev/null || true

      if ${pkgs.kmod}/bin/lsmod | grep -q "^nvidia"; then
        log_warn "NVIDIA modules may still be loaded"
        return 1
      fi

      log_info "NVIDIA modules unloaded"
      return 0
    }

    load_vfio_modules() {
      log_info "Loading VFIO modules..."
      ${pkgs.kmod}/bin/modprobe vfio_pci 2>/dev/null || true
      ${pkgs.kmod}/bin/modprobe vfio_iommu_type1 2>/dev/null || true
    }

    switch_to_nvidia() {
      log_info "Switching GPU to NVIDIA driver..."

      load_vfio_modules

      for addr in "''${PCI_ADDRESSES[@]}"; do
        unbind_driver "$addr"
      done

      load_nvidia_modules

      for i in "''${!PCI_ADDRESSES[@]}"; do
        addr="''${PCI_ADDRESSES[$i]}"
        device_id="''${DEVICE_IDS[$i]}"

        # Audio devices bind to snd_hda_intel, GPU to nvidia
        if [[ "$device_id" == *"228b"* ]] || [[ "$addr" == *".1" ]]; then
          bind_driver "$addr" "snd_hda_intel"
        else
          bind_driver "$addr" "nvidia"
        fi
      done

      log_info "GPU switched to NVIDIA driver"
      show_status
    }

    switch_to_vfio() {
      log_info "Switching GPU to VFIO-PCI driver..."

      unload_nvidia_modules || true

      load_vfio_modules

      for addr in "''${PCI_ADDRESSES[@]}"; do
        unbind_driver "$addr"
        bind_driver "$addr" "vfio-pci"
      done

      # Verify the switch
      local switch_success=true
      for addr in "''${PCI_ADDRESSES[@]}"; do
        local driver=$(get_current_driver "$addr")
        if [ "$driver" != "vfio-pci" ]; then
          log_error "Device $addr failed to bind to vfio-pci (current: $driver)"
          switch_success=false
        fi
      done

      if [ "$switch_success" = "true" ]; then
        log_info "GPU switched to VFIO-PCI driver"
      else
        log_error "Some devices failed to switch to VFIO-PCI"
      fi

      show_status
    }

    show_status() {
      echo ""
      log_info "Current GPU driver status:"
      echo "-----------------------------------"
      for addr in "''${PCI_ADDRESSES[@]}"; do
        driver=$(get_current_driver "$addr")
        printf "  %-12s -> %s\n" "$addr" "$driver"
      done
      echo "-----------------------------------"
    }

    usage() {
      echo "Usage: gpu-switch <command>"
      echo ""
      echo "Commands:"
      echo "  nvidia    Switch GPU to NVIDIA driver (for host use)"
      echo "  vfio      Switch GPU to VFIO-PCI driver (for VM passthrough)"
      echo "  status    Show current driver bindings"
      echo "  help      Show this help message"
      echo ""
      echo "Configured devices:"
      for i in "''${!PCI_ADDRESSES[@]}"; do
        echo "  ''${PCI_ADDRESSES[$i]} (''${DEVICE_IDS[$i]})"
      done
    }

    main() {
      local cmd="''${1:-help}"

      case "$cmd" in
        nvidia)
          check_root
          switch_to_nvidia
          ;;
        vfio)
          check_root
          switch_to_vfio
          ;;
        status)
          show_status
          ;;
        help|--help|-h)
          usage
          ;;
        *)
          log_error "Unknown command: $cmd"
          usage
          exit 1
          ;;
      esac
    }

    main "$@"
  '';
in
{
  options.nyx.virtualisation.desktop.gpuSwitch = {
    enable = mkEnableOption "GPU driver switching between NVIDIA and VFIO-PCI";

    pciAddresses = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "PCI bus addresses of GPU devices (e.g., 01:00.0)";
      example = [
        "01:00.0"
        "01:00.1"
      ];
    };

    deviceIds = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "PCI device IDs corresponding to pciAddresses (for reference)";
      example = [
        "10de:2489"
        "10de:228b"
      ];
    };

    defaultMode = mkOption {
      type = types.enum [
        "nvidia"
        "vfio"
      ];
      default = "vfio";
      description = "Default driver mode at boot (nvidia or vfio)";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ gpuSwitchScript ];

    security.sudo.extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          {
            command = "${gpuSwitchScript}/bin/gpu-switch";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    boot.kernelModules = [
      "vfio_pci"
      "vfio"
      "vfio_iommu_type1"
    ];
  };
}
