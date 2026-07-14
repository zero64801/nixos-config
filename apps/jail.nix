{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nyx.apps.jail;

  /*
  Two seccomp BPF filters compiled at build time with libseccomp, modeled on
  flatpak's filter (deny kernel keyring, ptrace, perf, bpf, io_uring, module
  and mount plumbing, TIOCSTI/TIOCLINUX injection).

  base:     allows user namespaces and mounts because nested sandboxes (e.g.
            Steam's pressure-vessel runtime, browser sandboxes) create their
            own container inside the jail. This is the one hole flatpak closes
            that we cannot without breaking those runtimes. To shrink it, both
            filters deny creating network namespaces and netfilter netlink,
            which gates the bulk of the userns-reachable kernel LPE surface
            (nf_tables, net-sched); the residual is mainly fs drivers mounted
            from a userns, which seccomp cannot express.
  hardened: closes that hole too, matching flatpak. Default for the generic
            profile; the steam profile auto-selects base, --userns opts into
            base elsewhere.
  */
  seccompFilters = pkgs.runCommandCC "nyx-jail-seccomp" {
    buildInputs = [ pkgs.libseccomp.dev ];
  } ''
    cat > gen.c << 'EOF'
    #define _GNU_SOURCE
    #include <sched.h>
    #include <seccomp.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <linux/netlink.h>

    #ifndef TIOCSTI
    #define TIOCSTI 0x5412
    #endif
    #ifndef TIOCLINUX
    #define TIOCLINUX 0x541C
    #endif

    static void deny(scmp_filter_ctx ctx, const char *name) {
      int nr = seccomp_syscall_resolve_name(name);
      if (nr == __NR_SCMP_ERROR) {
        fprintf(stderr, "unknown syscall: %s\n", name);
        exit(1);
      }
      if (seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), nr, 0) < 0) {
        fprintf(stderr, "rule failed: %s\n", name);
        exit(1);
      }
    }

    int main(int argc, char **argv) {
      if (argc != 3) return 1;
      int hardened = strcmp(argv[1], "hardened") == 0;

      scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
      if (!ctx) return 1;
      /* cover 32-bit programs */
      seccomp_arch_add(ctx, SCMP_ARCH_X86);
      seccomp_arch_add(ctx, SCMP_ARCH_X32);

      const char *base[] = {
        "init_module", "finit_module", "delete_module",
        "kexec_load", "kexec_file_load",
        "swapon", "swapoff", "reboot", "syslog", "acct",
        "quotactl", "quotactl_fd",
        "add_key", "request_key", "keyctl",
        "ptrace", "process_vm_readv", "process_vm_writev",
        "perf_event_open", "bpf", "lookup_dcookie",
        "open_by_handle_at", "userfaultfd", "kcmp",
        "io_uring_setup", "io_uring_enter", "io_uring_register",
      };
      for (unsigned i = 0; i < sizeof(base) / sizeof(*base); i++)
        deny(ctx, base[i]);

      /* terminal input injection */
      seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
        SCMP_A1(SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, TIOCSTI));
      seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
        SCMP_A1(SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, TIOCLINUX));

      /* base keeps user namespaces for pressure-vessel; a fresh netns is the
         cheap ticket to CAP_NET_ADMIN kernel surface (nf_tables, net-sched),
         and nothing we run creates one, so deny owning a netns and netfilter
         netlink in both filters. */
      seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(socket), 2,
        SCMP_A0(SCMP_CMP_EQ, AF_NETLINK),
        SCMP_A2(SCMP_CMP_EQ, NETLINK_NETFILTER));
      seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(unshare), 1,
        SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_NEWNET, CLONE_NEWNET));
      seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(clone), 1,
        SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_NEWNET, CLONE_NEWNET));
      /* ENOSYS so glibc falls back to plain clone, keeping it filterable */
      seccomp_rule_add(ctx, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0);

      if (hardened) {
        const char *extra[] = {
          "mount", "umount2", "pivot_root", "move_mount",
          "fsopen", "fsconfig", "fsmount", "fspick", "open_tree",
          "mount_setattr", "setns", "unshare",
        };
        for (unsigned i = 0; i < sizeof(extra) / sizeof(*extra); i++)
          deny(ctx, extra[i]);
        seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(clone), 1,
          SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_NEWUSER, CLONE_NEWUSER));
      }

      int fd = open(argv[2], O_CREAT | O_WRONLY | O_TRUNC, 0644);
      if (fd < 0 || seccomp_export_bpf(ctx, fd) < 0) return 1;
      seccomp_release(ctx);
      return 0;
    }
    EOF
    $CC -Wall -o gen gen.c -lseccomp
    mkdir -p $out
    ./gen base $out/base.bpf
    ./gen hardened $out/hardened.bpf
  '';

  nyx-jail = pkgs.writeShellApplication {
    name = "nyx-jail";
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.xdg-dbus-proxy
      pkgs.coreutils
    ];
    text = ''
      usage() {
        cat >&2 << 'USAGE'
      nyx-jail: bubblewrap sandbox (masked $HOME, seccomp, filtered D-Bus).

      Usage: nyx-jail [OPTIONS] -- COMMAND...

        --profile NAME  steam | generic | auto (default auto: steam when the
                        STEAM_COMPAT_* environment is present, else generic)
        --no-net        deny network (unshare the network namespace)
        --hardened      block user namespaces and mount even for steam
        --userns        allow user namespaces (automatic for steam; needed by
                        nested sandboxes: browsers, Electron, pressure-vessel)
        --no-dbus       no session bus at all
        --talk NAME     allow talking to a session bus name (repeatable)
        --portal        allow xdg-desktop-portal (file dialogs, doc portal)
        --host-etc      bind the whole host /etc instead of the minimal set
        --share-home    do NOT mask $HOME (escape hatch; rarely wanted)
        --ro PATH       extra read-only bind (repeatable)
        --rw PATH       extra read-write bind (repeatable)
        --env NAME      forward a host env var not in the allowlist (repeatable)
        --env-prefix P  forward all host env vars starting with P (repeatable)
        --debug         print the bwrap command line and dropped env vars to stderr

      Steam launch options:  nyx-jail -- %command%
      Sketchy binary:        nyx-jail --no-net -- ./unknown-thing
      USAGE
        exit 2
      }

      net=1 dbus=1 debug=0 mask_home=1 profile=auto harden=auto
      portal=0 host_etc=0
      extra_ro=() extra_rw=() talk=() extra_env=() extra_env_prefix=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --profile) [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
          --no-net) net=0; shift ;;
          --hardened) harden=1; shift ;;
          --userns) harden=0; shift ;;
          --no-dbus) dbus=0; shift ;;
          --talk) [ $# -ge 2 ] || usage; talk+=("$2"); shift 2 ;;
          --portal) portal=1; shift ;;
          --host-etc) host_etc=1; shift ;;
          --share-home) mask_home=0; shift ;;
          --ro) [ $# -ge 2 ] || usage; extra_ro+=("$2"); shift 2 ;;
          --rw) [ $# -ge 2 ] || usage; extra_rw+=("$2"); shift 2 ;;
          --env) [ $# -ge 2 ] || usage; extra_env+=("$2"); shift 2 ;;
          --env-prefix) [ $# -ge 2 ] || usage; extra_env_prefix+=("$2"); shift 2 ;;
          --debug) debug=1; shift ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      [ $# -gt 0 ] || usage
      case "$profile" in steam|generic|auto) ;; *) usage ;; esac

      # Steam sets STEAM_COMPAT_CLIENT_INSTALL_PATH for every compat-tool launch.
      if [ "$profile" = auto ]; then
        if [ -n "''${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]; then
          profile=steam
        else
          profile=generic
        fi
      fi

      # Flatpak-parity default: user namespaces blocked. Steam needs them for
      # pressure-vessel, so its profile falls back to the base filter.
      if [ "$harden" = auto ]; then
        if [ "$profile" = steam ]; then harden=0; else harden=1; fi
      fi
      filter=${seccompFilters}/base.bpf
      [ "$harden" -eq 1 ] && filter=${seccompFilters}/hardened.bpf

      RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      workdir="$PWD"
      [ "$profile" = steam ] && workdir="''${STEAM_COMPAT_INSTALL_PATH:-$PWD}"

      # --unshare-pid is load-bearing security, not cleanup: without a PID
      # namespace the fresh /proc still reflects the host, so the payload can
      # see every host process and signal (kill/stop) any of the same uid.
      args=(
        --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
        --die-with-parent --new-session
        --clearenv
        --proc /proc --dev /dev --tmpfs /tmp
        --perms 0700 --dir "$RUNTIME"
        --setenv XDG_RUNTIME_DIR "$RUNTIME"
        --chdir "$workdir"
      )
      [ "$mask_home" -eq 1 ] && args+=(--tmpfs "$HOME")
      [ "$net" -eq 1 ] || args+=(--unshare-net)

      # --clearenv wipes the child env. Re-export only a curated allowlist so
      # exported shell secrets (API tokens, ssh-agent) can never reach the
      # payload. bwrap has no globbing, so prefixes are matched here. DBUS_* is
      # excluded on purpose, the session bus is handled explicitly below.
      env_keep_exact=" PATH HOME USER LOGNAME SHELL TERM TERMINFO COLORTERM NO_COLOR
        LANG LANGUAGE TZ XMODIFIERS NIXOS_OZONE_WL ELECTRON_OZONE_PLATFORM_HINT "
      env_keep_prefix="LC_ XDG_ WAYLAND DISPLAY XAUTHORITY XCURSOR XKB_
        PULSE PIPEWIRE ALSA_ OBS_
        SDL_ MANGOHUD DXVK VKD3D VKBASALT ENABLE_VKBASALT ENABLE_GAMESCOPE GAMESCOPE
        PROTON WINE STEAM Steam PRESSURE_VESSEL GAMEMODE LD_LIBRARY_PATH LD_PRELOAD
        __GL __NV __VK __EGL NV_ VK_ MESA_ RADV_ AMD_ ZINK GALLIUM MVK_ NVD_
        DRI_ LIBGL_ vblank_mode mesa_ CUDA_
        LIBVA_ VDPAU_ GBM_ LIBDECOR_ FREETYPE FONTCONFIG_
        QT_ QML GTK_ GDK_ GST_ CLUTTER_ MOZ_ JAVA_ _JAVA_ WINIT_ DOTNET_"
      for v in "''${extra_env[@]}"; do env_keep_exact="$env_keep_exact$v "; done
      for p in "''${extra_env_prefix[@]}"; do env_keep_prefix="$env_keep_prefix $p"; done
      # NUL-delimited so values with spaces or newlines survive; carries the
      # value inline, avoiding indirect expansion (this bash lacks compgen).
      dropped=""
      while IFS= read -r -d "" _pair; do
        _name=''${_pair%%=*}
        case "$_name" in DBUS_*) continue ;; esac
        keep=0
        case "$env_keep_exact" in *" $_name "*) keep=1 ;; esac
        if [ "$keep" -eq 0 ]; then
          # shellcheck disable=SC2086
          for p in $env_keep_prefix; do
            case "$_name" in "$p"*) keep=1; break ;; esac
          done
        fi
        if [ "$keep" -eq 1 ]; then
          args+=(--setenv "$_name" "''${_pair#*=}")
        else
          dropped="$dropped $_name"
        fi
      done < /proc/self/environ
      # Names only, never values: a missing var shows up here, add it via --env.
      [ "$debug" -eq 1 ] && [ -n "$dropped" ] &&
        printf 'nyx-jail: dropped env:%s\n' "$dropped" >&2

      ro() { [ -e "$1" ] && args+=(--ro-bind "$1" "$1"); return 0; }
      rw() { [ -e "$1" ] && args+=(--bind "$1" "$1"); return 0; }
      dev() { [ -e "$1" ] && args+=(--dev-bind "$1" "$1"); return 0; }

      # Host system: store, current system, GPU userspace, config, sysfs.
      ro /nix/store
      ro /run/current-system
      ro /run/opengl-driver
      ro /run/opengl-driver-32
      ro /sys/dev/char
      ro /sys/devices
      ro /sys/bus
      ro /sys/class

      # Minimal /etc modeled on flatpak. NixOS static config lives in the
      # store, which is bound wholesale anyway, so entries under /etc/static
      # are recreated as symlinks: this trims accidental surface rather than
      # hiding secrets. --host-etc restores the old whole-/etc bind when an
      # app misses a file (or bind it one-off with --ro /etc/whatever).
      if [ "$host_etc" -eq 1 ]; then
        ro /etc
      else
        args+=(--tmpfs /etc --symlink /proc/self/mounts /etc/mtab)
        [ -L /etc/static ] && args+=(--symlink "$(readlink /etc/static)" /etc/static)
        etc_keep="passwd group hosts host.conf nsswitch.conf resolv.conf gai.conf
          services protocols rpc localtime zoneinfo os-release lsb-release
          fonts ssl pki alsa asound.conf pipewire pulse vulkan openal wireplumber"
        # shellcheck disable=SC2086
        for e in $etc_keep; do
          if [ -L "/etc/$e" ]; then
            target=$(readlink -f "/etc/$e") || continue
            case "$target" in
              /etc/static/*|/nix/store/*) args+=(--symlink "$target" "/etc/$e") ;;
              *) [ -e "$target" ] && args+=(--ro-bind "$target" "/etc/$e") ;;
            esac
          elif [ -e "/etc/$e" ]; then
            args+=(--ro-bind "/etc/$e" "/etc/$e")
          fi
        done
      fi

      # Neutralize the host machine-id, a world-readable stable fingerprint.
      # Random per launch like flatpak. A rare game keys save encryption off it.
      machine_id=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
      exec 8< <(printf '%s\n' "$machine_id")
      args+=(--ro-bind-data 8 /etc/machine-id)

      # GPU, input devices (rw for force feedback), udev metadata, shared
      # memory (many IPC and MIT-SHM paths need it writable).
      dev /dev/dri
      for n in /dev/nvidia*; do dev "$n"; done
      dev /dev/input
      ro /run/udev

      # Private shm, not the host's. A shared /dev/shm is a cross-process
      # channel to everything else on the host, and PipeWire uses sealed
      # memfds anyway.
      args+=(--tmpfs /dev/shm)

      # Session sockets only, not the whole runtime dir. Sockets are bound rw:
      # connect() needs write permission, a ro bind breaks them.
      for s in "$RUNTIME"/wayland-* "$RUNTIME"/pipewire-* "$RUNTIME"/gamescope-*; do
        [ -S "$s" ] && args+=(--bind "$s" "$s")
      done
      [ -d "$RUNTIME/pulse" ] && args+=(--bind "$RUNTIME/pulse" "$RUNTIME/pulse")

      # XWayland: no client isolation exists on X11; this hole is shared with
      # flatpak and only Wayland-native rendering avoids it.
      ro /tmp/.X11-unix
      [ -n "''${XAUTHORITY:-}" ] && ro "$XAUTHORITY"

      ro "$HOME/.config/MangoHud"

      # xdg-desktop-portal: file dialogs and friends run on the host, the app
      # only gets bus access to the portal names plus the document portal FUSE
      # mount (files the user granted through a dialog appear there). With no
      # .flatpak-info the portal treats us as an unsandboxed host app, so
      # portal-side permission tracking is weaker than flatpak's, but the
      # dialogs and doc grants work. GTK_USE_PORTAL nudges GTK apps to use it.
      if [ "$portal" -eq 1 ]; then
        talk+=(org.freedesktop.portal.Desktop org.freedesktop.portal.Documents)
        args+=(--setenv GTK_USE_PORTAL 1)
        [ -d "$RUNTIME/doc" ] && args+=(--bind "$RUNTIME/doc" "$RUNTIME/doc")
      fi

      if [ "$profile" = steam ]; then
        # gamemoded lives on the host and is driven over the session bus.
        talk+=(com.feralinteractive.GameMode)

        # Client dir, with session tokens and account data masked.
        client="''${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
        if [ -n "$client" ] && [ -d "$client" ]; then
          args+=(--ro-bind "$client" "$client")
          for d in config userdata logs; do
            [ -d "$client/$d" ] && args+=(--tmpfs "$client/$d")
          done
          for f in "$client"/ssfn*; do
            [ -f "$f" ] && args+=(--ro-bind /dev/null "$f")
          done
        fi

        # ~/.steam is mostly symlinks into the client dir (masked above) plus
        # steam.token, a live session token. Bind read-only, mask the token,
        # re-open only steam.pipe (the Steamworks fifo) read-write.
        if [ -d "$HOME/.steam" ]; then
          args+=(--ro-bind "$HOME/.steam" "$HOME/.steam")
          [ -e "$HOME/.steam/steam.token" ] && args+=(--ro-bind /dev/null "$HOME/.steam/steam.token")
          [ -p "$HOME/.steam/steam.pipe" ] && args+=(--bind "$HOME/.steam/steam.pipe" "$HOME/.steam/steam.pipe")
        fi

        [ -n "''${STEAM_COMPAT_DATA_PATH:-}" ] && rw "$STEAM_COMPAT_DATA_PATH"
        [ -n "''${STEAM_COMPAT_SHADER_PATH:-}" ] && rw "$STEAM_COMPAT_SHADER_PATH"
        if [ -n "''${STEAM_COMPAT_INSTALL_PATH:-}" ]; then
          rw "$STEAM_COMPAT_INSTALL_PATH"
        else
          rw "$PWD"
        fi
        IFS=: read -ra tools <<< "''${STEAM_COMPAT_TOOL_PATHS:-}"
        for t in "''${tools[@]}"; do ro "$t"; done
        IFS=: read -ra mounts <<< "''${STEAM_COMPAT_MOUNTS:-}"
        for m in "''${mounts[@]}"; do rw "$m"; done
      else
        # Generic: make the invocation directory reachable so --chdir and a
        # relative COMMAND (./thing) resolve. Read-only by default; the caller
        # adds --rw "$PWD" for write access. Skipped when it is $HOME (already
        # a tmpfs) to avoid un-masking the whole home.
        [ "$workdir" != "$HOME" ] && ro "$workdir"
      fi

      for p in "''${extra_ro[@]}"; do ro "$p"; done
      for p in "''${extra_rw[@]}"; do rw "$p"; done

      # Session bus: default-deny. A filtered proxy is only started when names
      # are explicitly allowed (via a profile or --talk); otherwise the bus is
      # removed entirely.
      proxy_pid=""
      if [ "$dbus" -eq 1 ] && [ ''${#talk[@]} -gt 0 ] && [ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        busdir=$(mktemp -d "$RUNTIME/nyx-jail.XXXXXX")
        trap '[ -n "$proxy_pid" ] && kill "$proxy_pid" 2>/dev/null; rm -rf "$busdir"' EXIT
        proxy_args=("$DBUS_SESSION_BUS_ADDRESS" "$busdir/bus" --filter)
        for name in "''${talk[@]}"; do proxy_args+=(--talk="$name"); done
        # --fd: the proxy writes one byte when the socket is ready and exits
        # when the fd closes, so it dies with this script even on SIGKILL
        # (the trap is only a fallback). fd 7 stays open for our lifetime.
        mkfifo "$busdir/sync"
        xdg-dbus-proxy --fd=9 "''${proxy_args[@]}" 9>"$busdir/sync" &
        proxy_pid=$!
        exec 7< "$busdir/sync"
        ready=0
        IFS= read -r -n 1 -t 10 -u 7 _ && ready=1
        if [ "$ready" -eq 1 ] && [ -S "$busdir/bus" ]; then
          args+=(
            --bind "$busdir/bus" "$RUNTIME/bus"
            --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$RUNTIME/bus"
          )
        else
          args+=(--unsetenv DBUS_SESSION_BUS_ADDRESS)
        fi
      else
        args+=(--unsetenv DBUS_SESSION_BUS_ADDRESS)
      fi

      if [ "$debug" -eq 1 ]; then
        printf 'nyx-jail: profile=%s bwrap' "$profile" >&2
        printf ' %q' "''${args[@]}" >&2
        printf '\n' >&2
      fi

      # No exec: the trap must outlive bwrap to reap the dbus proxy. bwrap
      # reads the filter from fd 9 before applying it and sanitizes the child's
      # fds itself, so 9 does not leak into the payload.
      exec 9< "$filter"
      bwrap --seccomp 9 "''${args[@]}" -- "$@"
    '';
  };
in
{
  options.nyx.apps.jail.enable =
    lib.mkEnableOption "nyx-jail general bubblewrap sandbox (masked HOME, seccomp, filtered D-Bus)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ nyx-jail ];
  };
}
