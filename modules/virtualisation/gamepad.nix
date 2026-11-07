{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) str;

  cfg = config.my.virtualisation.gamepad;

  deviceXml = pkgs.writeText "vm-pad-hostdev.xml" ''
    <hostdev mode="subsystem" type="usb" managed="yes">
      <source><vendor id="0x${cfg.vendorId}"/><product id="0x${cfg.productId}"/></source>
    </hostdev>
  '';

  vm-pad = pkgs.writeShellApplication {
    name = "vm-pad";
    runtimeInputs = [
      pkgs.libvirt
      pkgs.gnugrep
      pkgs.coreutils
    ];
    text = ''
      usage() {
        echo "Usage: vm-pad on <domain> | off | status" >&2
        exit 2
      }

      as_root() {
        [ "$(id -u)" -eq 0 ] || exec /run/wrappers/bin/pkexec "$(readlink -f "$0")" "$@"
      }

      attached_domains() {
        virsh -r -c qemu:///system list --name | while IFS= read -r d; do
          [ -n "$d" ] || continue
          xml=$(virsh -r -c qemu:///system dumpxml "$d" 2>/dev/null) || continue
          if printf '%s' "$xml" | grep -q 'vendor id="0x${cfg.vendorId}"' \
            && printf '%s' "$xml" | grep -q 'product id="0x${cfg.productId}"'; then
            echo "$d"
          fi
        done
      }

      case "''${1:-}" in
        on)
          [ -n "''${2:-}" ] || usage
          case "$2" in
            -*|*[!A-Za-z0-9._-]*) echo "vm-pad: invalid domain name '$2'" >&2; exit 2 ;;
          esac
          as_root "$@"
          virsh -c qemu:///system attach-device --domain "$2" --file ${deviceXml} --live
          echo "vm-pad: attached ${cfg.vendorId}:${cfg.productId} to $2"
          ;;
        off)
          as_root "$@"
          doms=$(attached_domains)
          if [ -z "$doms" ]; then
            echo "vm-pad: not attached to any running domain" >&2
            exit 1
          fi
          for d in $doms; do
            virsh -c qemu:///system detach-device --domain "$d" --file ${deviceXml} --live
            echo "vm-pad: detached from $d"
          done
          ;;
        status)
          doms=$(attached_domains)
          if [ -n "$doms" ]; then
            echo "$doms"
          else
            echo "vm-pad: not attached"
          fi
          ;;
        *)
          usage
          ;;
      esac
    '';
  };
in
{
  options.my.virtualisation.gamepad = {
    enable = mkEnableOption "vm-pad CLI for hot-attaching a USB gamepad to libvirt domains";

    vendorId = mkOption {
      type = str;
      example = "045e";
      description = "USB vendor ID of the gamepad (lsusb ID column, vendor half).";
    };

    productId = mkOption {
      type = str;
      example = "028e";
      description = "USB product ID of the gamepad (lsusb ID column, product half).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ vm-pad ];

    my.security.pkexecNoAuth = [ { program = "${vm-pad}/bin/vm-pad"; } ];

    programs.fish.shellAbbrs = {
      pad-on = "vm-pad on";
      pad-off = "vm-pad off";
    };
  };
}
