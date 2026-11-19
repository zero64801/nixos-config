# nix build --no-link -L .#tests.virtualisation.vm-gpu
{
  host,
}:

let
  inherit (host) pkgs;

  # First on the tool's PATH. It answers as virsh, and as an id that says root so a start does not reach for pkexec.
  fakeLibvirt = pkgs.symlinkJoin {
    name = "fake-libvirt";
    paths = [
      (pkgs.writeShellScriptBin "id" "echo 0")
      (pkgs.writeShellScriptBin "virsh" ''
        echo "$*" >> "$VIRSH_LOG"
        case "$*" in
          *domstate*) echo "shut off" ;;
          *--security-info*) echo "<domain><devices><graphics type='spice' passwd='SECRET'/></devices></domain>" ;;
          *dumpxml*) echo "<domain><devices><graphics type='spice'/></devices></domain>" ;;
        esac
      '')
    ];
  };

  inherit
    (host.evaluate {
      config = {
        virtualisation.libvirtd.package = fakeLibvirt;
        my.virtualisation.gpuMode = {
          enable = true;
          domains.guest = { };
          modes.virtual.stripHostdevs = [ "01:00.0" ];
        };
      };
    })
    config
    ;
in
host.needs [ "modules/virtualisation/gpu-mode.nix" ] (
  pkgs.runCommand "vm-gpu-test" { nativeBuildInputs = [ config.my.virtualisation.gpuMode.package ]; } ''
    set -euo pipefail
    fail() { echo "vm-gpu: $1" >&2; exit 1; }
    export VIRSH_LOG=$PWD/log

    vm-gpu start guest || fail "a start with no once override reported failure"
    grep -qx "start guest" log || fail "the start did not use the persistent definition"

    : > log
    vm-gpu start guest virtual || fail "a start in an editing mode failed"
    grep -qx "dumpxml guest --inactive --security-info" log || fail "a start read the definition without its passwords"
    grep -q "^create " log || fail "the editing mode did not start a transient definition"

    : > log
    preview=$(vm-gpu xml guest virtual) || fail "the preview failed"
    grep -qx -- "-r dumpxml guest --inactive" log || fail "the preview did not use the read only connection"
    case "$preview" in *SECRET*) fail "the preview printed a password" ;; esac
    case "$preview" in *"<domain>"*) ;; *) fail "the preview printed no definition" ;; esac

    touch $out
  ''
)
