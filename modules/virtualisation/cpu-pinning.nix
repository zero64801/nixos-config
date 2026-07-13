{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) attrsOf listOf int str submodule;

  cfg = config.nyx.virtualisation.cpuPinning;

  virsh = "${pkgs.libvirt}/bin/virsh";

  modePattern = lib.concatStringsSep "|" (lib.attrNames cfg.modes);
  domainPattern = lib.concatStringsSep "|" cfg.domains;

  modeCase = lib.concatStrings (lib.mapAttrsToList (name: m: ''
        ${name})
          VCPU_PINS="${lib.concatMapStringsSep " " toString m.vcpuPins}"
          EMU_CPUS="${m.emulatorCpus}"
          IO_CPUS="${m.iothreadCpus}"
          ;;
  '') cfg.modes);

  /*
  Shared shell layer for the hook and the root helper. Host CPU ownership is
  tracked through marker files under /run so concurrent VMs never clobber each
  other's isolation: every recompute derives the host set from the union of
  running claims instead of assuming it owns the whole machine.
  */
  helpers = ''
    STATE_DIR=/var/lib/nyx/vm-mode
    OVERRIDE_DIR=/run/nyx/vm-mode
    RUN_DIR=/run/nyx/vm-cpus

    # One-shot override (vm-mode --once) wins over the persistent state file.
    mode_of() {
      local m
      m=$(cat "$OVERRIDE_DIR/$1" 2>/dev/null || true)
      case "$m" in
        ${modePattern}) printf '%s' "$m"; return ;;
      esac
      m=$(cat "$STATE_DIR/$1" 2>/dev/null || true)
      case "$m" in
        ${modePattern}) ;;
        *) m="${cfg.defaultMode}" ;;
      esac
      printf '%s' "$m"
    }

    mode_vars() {
      case "$1" in
${modeCase}
        *) echo "unknown mode: $1" >&2; exit 1 ;;
      esac
      VM_LIST=$(printf '%s\n' $VCPU_PINS | sort -nu | xargs)
    }

    list_to_cpuset() { printf '%s' "$1" | tr -s ' ' ','; }

    host_allowed_list() {
      local claimed f c out=""
      claimed=" $(cat "$RUN_DIR"/* 2>/dev/null | tr '\n' ' ') "
      for c in $(seq 0 $(($(nproc) - 1))); do
        case "$claimed" in
          *" $c "*) ;;
          *) out="$out$c " ;;
        esac
      done
      printf '%s' "$out" | xargs
    }

    apply_slices() {
      systemctl set-property --runtime -- system.slice AllowedCPUs="$1"
      systemctl set-property --runtime -- user.slice   AllowedCPUs="$1"
      systemctl set-property --runtime -- init.scope   AllowedCPUs="$1"
    }

    set_epp() {
      local pref="$1" c
      shift
      for c in "$@"; do
        echo "$pref" > "/sys/devices/system/cpu/cpu$c/cpufreq/energy_performance_preference" 2>/dev/null || true
      done
    }

    # Keep device interrupts off the guest's cores while it runs.
    irq_steer() {
      local csv f c mask=0
      csv=$(list_to_cpuset "$1")
      for c in $1; do mask=$((mask | (1 << c))); done
      printf '%x' "$mask" > /proc/irq/default_smp_affinity 2>/dev/null || true
      for f in /proc/irq/*/smp_affinity_list; do
        echo "$csv" > "$f" 2>/dev/null || true
      done
    }

    recompute_host() {
      local allowed
      allowed=$(host_allowed_list)
      apply_slices "$(list_to_cpuset "$allowed")"
      irq_steer "$allowed"
    }

    # Reset EPP only on cores no running VM still claims.
    epp_restore() {
      local claimed c
      claimed=" $(cat "$RUN_DIR"/* 2>/dev/null | tr '\n' ' ') "
      for c in $1; do
        case "$claimed" in
          *" $c "*) ;;
          *) set_epp balance_performance "$c" ;;
        esac
      done
    }
  '';

  # Runs outside hook context (libvirt hooks must never call back into the
  # API); waits for the domain then repins live.
  vm-pin-apply = pkgs.writeShellScript "vm-pin-apply" ''
    set -euo pipefail
    DOM="$1"
    MODE="$2"
    ${helpers}
    mode_vars "$MODE"

    for _ in $(seq 1 20); do
      ${virsh} domstate "$DOM" 2>/dev/null | grep -q running && break
      sleep 0.5
    done

    idx=0
    for p in $VCPU_PINS; do
      ${virsh} vcpupin "$DOM" "$idx" "$p" --live >/dev/null
      idx=$((idx + 1))
    done
    ${virsh} emulatorpin "$DOM" "$EMU_CPUS" --live >/dev/null
    ${virsh} iothreadpin "$DOM" 1 "$IO_CPUS" --live >/dev/null 2>&1 || true
  '';

  cpuPinHook = pkgs.writeShellScript "libvirt-hook-cpu-pin" ''
    set -euo pipefail
    GUEST_NAME="$1"
    HOOK_NAME="''${2:-}"
    STATE_NAME="''${3:-}"

    case "$GUEST_NAME" in
      ${domainPattern}) ;;
      *) exit 0 ;;
    esac

    ${helpers}
    mkdir -p "$RUN_DIR"
    exec 9>"$RUN_DIR.lock"
    flock 9

    MODE=$(mode_of "$GUEST_NAME")
    mode_vars "$MODE"

    case "$HOOK_NAME/$STATE_NAME" in
      prepare/begin)
        printf '%s\n' "$VM_LIST" > "$RUN_DIR/$GUEST_NAME"
        recompute_host
        set_epp performance $VM_LIST
        ;;
      started/begin)
        systemd-run --collect --no-block --unit="vm-pin-$GUEST_NAME-$$" \
          ${vm-pin-apply} "$GUEST_NAME" "$MODE"
        ;;
      release/end)
        rm -f "$RUN_DIR/$GUEST_NAME" "$OVERRIDE_DIR/$GUEST_NAME"
        recompute_host
        epp_restore "$VM_LIST"
        ;;
    esac
  '';

  # Passwordless via polkit for wheel: argv is only a whitelisted domain name,
  # the mode is read from the root-visible state file, so nothing attacker
  # controlled reaches privileged execution.
  vm-mode-root = pkgs.writeShellScript "vm-mode-root" ''
    set -euo pipefail
    DOM="''${1:-}"
    case "$DOM" in
      ${domainPattern}) ;;
      *) echo "vm-mode-root: unknown domain '$DOM'" >&2; exit 1 ;;
    esac

    ${helpers}
    MODE=$(mode_of "$DOM")
    mode_vars "$MODE"

    ${virsh} domstate "$DOM" 2>/dev/null | grep -q running || exit 0

    mkdir -p "$RUN_DIR"
    exec 9>"$RUN_DIR.lock"
    flock 9

    OLD_LIST=$(cat "$RUN_DIR/$DOM" 2>/dev/null || true)
    ${vm-pin-apply} "$DOM" "$MODE"
    printf '%s\n' "$VM_LIST" > "$RUN_DIR/$DOM"
    recompute_host
    set_epp performance $VM_LIST
    [ -n "$OLD_LIST" ] && epp_restore "$OLD_LIST"
    echo "vm-mode: applied '$MODE' to $DOM live"
  '';

  vm-mode = pkgs.writeShellScriptBin "vm-mode" ''
    set -euo pipefail
    STATE_DIR=/var/lib/nyx/vm-mode
    OVERRIDE_DIR=/run/nyx/vm-mode
    DOMAINS="${lib.concatStringsSep " " cfg.domains}"
    MODES="${lib.concatStringsSep " " (lib.attrNames cfg.modes)}"

    saved_mode() {
      local m
      m=$(cat "$STATE_DIR/$1" 2>/dev/null || true)
      case "$m" in
        ${modePattern}) printf '%s' "$m" ;;
        *) printf '%s' "${cfg.defaultMode}" ;;
      esac
    }

    # Effective mode: one-shot override beats the saved one.
    current_mode() {
      local m
      m=$(cat "$OVERRIDE_DIR/$1" 2>/dev/null || true)
      case "$m" in
        ${modePattern}) printf '%s (once)' "$m" ;;
        *) saved_mode "$1" ;;
      esac
    }

    state_of() {
      ${virsh} -c qemu:///system domstate "$1" 2>/dev/null | head -1 || echo unknown
    }

    ONCE=0
    ARGS=""
    for a in "$@"; do
      case "$a" in
        --once) ONCE=1 ;;
        *) ARGS="$ARGS $a" ;;
      esac
    done
    set -- $ARGS

    if [ $# -eq 0 ]; then
      printf '%-12s %-10s %s\n' DOMAIN MODE STATE
      for d in $DOMAINS; do
        printf '%-12s %-10s %s\n' "$d" "$(current_mode "$d")" "$(state_of "$d")"
      done
      exit 0
    fi

    DOM="$1"
    case " $DOMAINS " in
      *" $DOM "*) ;;
      *) echo "vm-mode: unknown domain '$DOM' (have: $DOMAINS)" >&2; exit 1 ;;
    esac

    if [ $# -eq 1 ]; then
      echo "$(current_mode "$DOM")"
      exit 0
    fi

    MODE="$2"
    case " $MODES " in
      *" $MODE "*) ;;
      *) echo "vm-mode: unknown mode '$MODE' (have: $MODES)" >&2; exit 1 ;;
    esac

    if [ "$ONCE" -eq 1 ]; then
      printf '%s\n' "$MODE" > "$OVERRIDE_DIR/$DOM"
      SCOPE="once (reverts to '$(saved_mode "$DOM")' after shutdown)"
    else
      printf '%s\n' "$MODE" > "$STATE_DIR/$DOM"
      rm -f "$OVERRIDE_DIR/$DOM"
      SCOPE="permanent"
    fi

    if state_of "$DOM" | grep -q running; then
      /run/wrappers/bin/pkexec ${vm-mode-root} "$DOM"
      echo "vm-mode: '$DOM' -> '$MODE' ($SCOPE)"
    else
      echo "vm-mode: '$DOM' -> '$MODE' at next start ($SCOPE)"
    fi
  '';
in
{
  options.nyx.virtualisation.cpuPinning = {
    enable = mkEnableOption "per-domain CPU pinning profiles switchable at runtime via vm-mode";

    domains = mkOption {
      type = listOf str;
      default = [ ];
      description = "Libvirt domains managed by the pinning hook and vm-mode.";
    };

    defaultMode = mkOption {
      type = str;
      default = "classic";
      description = "Mode assumed when a domain has no saved state.";
    };

    modes = mkOption {
      default = { };
      description = "CPU profiles selectable per domain. vcpuPins is ordered: entry N pins vCPU N.";
      type = attrsOf (submodule {
        options = {
          vcpuPins = mkOption {
            type = listOf int;
            description = "Physical CPU for each vCPU, in vCPU order.";
          };
          emulatorCpus = mkOption {
            type = str;
            description = "cpuset for QEMU emulator threads (opposite CCD).";
          };
          iothreadCpus = mkOption {
            type = str;
            description = "cpuset for iothread 1.";
          };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.modes ? ${cfg.defaultMode};
        message = "nyx.virtualisation.cpuPinning.defaultMode '${cfg.defaultMode}' is not among the defined modes.";
      }
    ];

    environment.systemPackages = [ vm-mode ];

    systemd.tmpfiles.rules = [
      "d /var/lib/nyx 0755 root root -"
      "d /var/lib/nyx/vm-mode 2775 root libvirtd -"
      "d /run/nyx 0755 root root -"
      "d /run/nyx/vm-mode 2775 root libvirtd -"
    ];

    nyx.persistence.directories = [ "/var/lib/nyx/vm-mode" ];

    virtualisation.libvirtd.hooks.qemu."15-cpu-pin" = cpuPinHook;
    systemd.services.libvirtd-config.restartTriggers = [ cpuPinHook ];

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.policykit.exec" &&
            action.lookup("command_line") &&
            action.lookup("command_line").indexOf("${vm-mode-root}") === 0 &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
