{
  lib,
  callPackage,
  runCommand,
  runtimeShell,
  writeShellApplication,
  bubblewrap,
  coreutils,
  dbus,
  gnused,
  iproute2,
  passt,
  wayland-proxy-virtwl,
  xdg-dbus-proxy,
  xwayland-satellite,
}:

let
  mkFilter = callPackage ./seccomp.nix { };
  profiles = import ./profiles.nix;

  defaults = {
    name = null;
    binaries = null;
    # Renames the shims (bin/<prefix><name>) so a confined and an unconfined
    # build of the same package can be installed side by side.
    binPrefix = "";
    profile = [ ];
    network = false;
    wayland = false;
    waylandProxy = false;
    x11 = "none";
    pipewire = false;
    pulse = false;
    gpu = false;
    sysfs = false;
    portals = false;
    a11y = false;
    home = "private";
    devices = [ ];
    binds = {
      ro = [ ];
      rw = [ ];
    };
    # { link, target } pairs created inside the sandbox. connect(2) follows
    # them, so this reaches another sandbox's socket. bind(2) does not, a
    # server needs runtimeDir = "shared" instead.
    symlinks = [ ];
    # "shared" puts the runtime dir on the host at app/<appId>, so sockets the
    # app creates there are reachable by other sandboxes.
    runtimeDir = "private";
    dbus = {
      filter = true;
      log = false;
      session = {
        talk = [ ];
        own = [ ];
        call = [ ];
        broadcast = [ ];
      };
      system = {
        talk = [ ];
        call = [ ];
      };
    };
    env = { };
    envPassthrough = [ ];
    networkPorts = {
      toHost = [ ];
      fromHost = [ ];
    };
    extraPastaArgs = [ ];
    seccomp = {
      enable = true;
      nesting = false;
      multiarch = false;
      devel = false;
      bluetooth = false;
      can = false;
    };
    extraBwrapArgs = [ ];
  };

  # Profile lists append rather than replace, derivations are leaves.
  merge =
    a: b:
    a
    // lib.mapAttrs (
      name: bv:
      let
        av = a.${name} or null;
      in
      if lib.isList av && lib.isList bv then
        av ++ bv
      else if lib.isAttrs av && lib.isAttrs bv && !(av ? outPath) && !(bv ? outPath) then
        merge av bv
      else
        bv
    ) b;

  # NixOS /etc is mostly symlinks into /etc/static, partial rebinds break lookups.
  maskedFiles = [
    "/etc/shadow"
    "/etc/gshadow"
  ];
  maskedDirs = [ "/etc/ssh" ];

  # Flatpak's sysfs allowlist, enough for libdrm to map a card node to its PCI device.
  sysfsDirs = [
    "/sys/block"
    "/sys/bus"
    "/sys/class"
    "/sys/dev"
    "/sys/devices"
  ];

  normaliseBind =
    b:
    if lib.isString b then
      {
        from = b;
        to = b;
      }
    else
      b;

  # Flatpak grants these implicitly, single-instance activation and MPRIS need them.
  ownedNames = id: [
    id
    "${id}.*"
    "org.mpris.MediaPlayer2.${id}.*"
  ];
in

# fix so overriding a confined package reruns the whole wrap.
lib.fix (
  confine: settings:

let
  confineAgain = p: confine (settings // { package = p; });

  selected = map (p: profiles.${p} or (throw "confine: no such profile ${p}")) (
    settings.profile or [ ]
  );

  cfg = lib.foldl' merge defaults (selected ++ [ (removeAttrs settings [ "profile" ]) ]);

  inherit (cfg) appId package;

  checked =
    if unknownKeys != [ ] then
      throw "confine: unknown permission${lib.optionalString (lib.length unknownKeys > 1) "s"} ${
        lib.concatStringsSep ", " unknownKeys
      }"
    # appId is interpolated into the launcher unquoted, so revalidate here.
    else if builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+)+" appId == null then
      throw "confine: appId must be reverse-DNS, e.g. com.vendor.App, not ${builtins.toJSON appId}"
    # The names are interpolated into the launcher's copy loop.
    else if
      lib.any (v: !lib.isString v || builtins.match "[A-Za-z_][A-Za-z0-9_]*" v == null)
        cfg.envPassthrough
    then
      throw "confine: envPassthrough entries must be environment variable names"
    # The prefix lands in file names and Exec lines.
    else if !lib.isString cfg.binPrefix || builtins.match "[A-Za-z0-9_.-]*" cfg.binPrefix == null then
      throw "confine: binPrefix may only contain letters, digits, dot, dash and underscore"
    else if !lib.all (s: s ? link && s ? target && lib.isString s.link && lib.isString s.target) cfg.symlinks then
      throw "confine: symlinks entries must be { link, target } string pairs"
    else if !lib.elem cfg.runtimeDir [ "private" "shared" ] then
      throw "confine: runtimeDir must be private or shared, not ${builtins.toJSON cfg.runtimeDir}"
    else
      x: x;
  name = if cfg.name != null then cfg.name else package.pname or package.name;

  # "isolated" runs a pasta userspace stack, host loopback and other host
  # subnets are unreachable but the LAN still routes. Booleans mean none/host.
  networkMode =
    if lib.isBool cfg.network then
      (if cfg.network then "host" else "none")
    else if lib.elem cfg.network [ "none" "host" "isolated" ] then
      cfg.network
    else
      throw "confine: network must be none, host or isolated, not ${toString cfg.network}";

  isolatedNetwork = networkMode == "isolated";
  hasNetwork = networkMode != "none";

  # Controls what $HOME contains, the path is never relocated like Flatpak's
  # ~/.var/app. Booleans are rejected, "home = false" would read as no home.
  homeMode =
    if lib.elem cfg.home [ "private" "ephemeral" "host" ] then
      cfg.home
    else
      throw "confine: home must be private, ephemeral or host, not ${builtins.toJSON cfg.home}";

  # A misspelled permission would otherwise silently skip a restriction.
  unknownKeys = lib.subtractLists (lib.attrNames defaults ++ [ "package" "appId" ]) (
    lib.attrNames settings
  );

  portSpec =
    ports:
    if ports == [ ] then
      "none"
    else if lib.all lib.isInt ports then
      lib.concatMapStringsSep "," toString ports
    else
      throw "confine: networkPorts entries must be integers";

  filter = mkFilter { inherit (cfg.seccomp) nesting multiarch devel bluetooth can; };

  useSystemBus = cfg.dbus.system.talk != [ ] || cfg.dbus.system.call != [ ];
  useProxy = cfg.dbus.filter;
  isolatedX11 = cfg.x11 == "isolated";

  # pasta closes inherited descriptors, so the filter opens on its far side.
  # The seccomp fd is allocated, a fixed number could collide with bash's own.
  innerScript =
    lib.optionalString cfg.seccomp.enable ''
      exec {confine_seccomp_fd}<"$CONFINE_FILTER"
    ''
    + "exec bwrap "
    + lib.optionalString cfg.seccomp.enable "--seccomp \"$confine_seccomp_fd\" "
    + "\"$@\""
    + lib.optionalString cfg.portals " 4>\"$CONFINE_INFO\"";

  sessionProxyArgs =
    [ "--filter" ]
    ++ lib.optional cfg.dbus.log "--log"
    ++ map (n: "--talk=${n}") (lib.unique cfg.dbus.session.talk)
    ++ map (n: "--own=${n}") (lib.unique (ownedNames appId ++ cfg.dbus.session.own))
    ++ map (n: "--call=${n}") (lib.unique cfg.dbus.session.call)
    ++ map (n: "--broadcast=${n}") (lib.unique cfg.dbus.session.broadcast);

  systemProxyArgs =
    [ "--filter" ]
    ++ lib.optional cfg.dbus.log "--log"
    ++ map (n: "--talk=${n}") (lib.unique cfg.dbus.system.talk)
    ++ map (n: "--call=${n}") (lib.unique cfg.dbus.system.call);

  # From flatpak_run_add_a11y_dbus_args() in common/flatpak-run-dbus.c. The
  # a11y bus carries keystrokes, so per-method rules rather than a talk rule.
  a11yProxyArgs = [
    "--filter"
    "--sloppy-names"
    "--broadcast=org.a11y.atspi.Registry.EventListenerRegistered=@/org/a11y/atspi/registry"
    "--broadcast=org.a11y.atspi.Registry.EventListenerDeregistered=@/org/a11y/atspi/registry"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.Socket.Embed@/org/a11y/atspi/accessible/root"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.Socket.Unembed@/org/a11y/atspi/accessible/root"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.Registry.GetRegisteredEvents@/org/a11y/atspi/registry"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.GetKeystrokeListeners@/org/a11y/atspi/registry/deviceeventcontroller"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.GetDeviceEventListeners@/org/a11y/atspi/registry/deviceeventcontroller"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.NotifyListenersSync@/org/a11y/atspi/registry/deviceeventcontroller"
    "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.NotifyListenersAsync@/org/a11y/atspi/registry/deviceeventcontroller"
  ];

  useA11y = cfg.a11y && useProxy;

  # The readiness fd keeps the proxy alive, the sandbox must not inherit it.
  closeSyncFd = lib.optionalString useProxy " {sync_fd}<&-";
  useWaylandProxy = cfg.waylandProxy && cfg.wayland;

  staticArgs =
    [ "--unshare-all" ]
    # In isolated mode this keeps pasta's namespace rather than the host's.
    ++ lib.optional hasNetwork "--share-net"
    ++ [
      "--die-with-parent"
      "--clearenv"
      "--proc"
      "/proc"
      "--dev"
      "/dev"
      "--tmpfs"
      "/tmp"
      # Some programs scratch in /var/tmp and fail when it does not exist.
      "--tmpfs"
      "/var/tmp"
      # Only named /run paths exist inside, keeping /run/wrappers setuid out.
      "--ro-bind"
      "/nix/store"
      "/nix/store"
      # -try so this works where no NixOS system profile exists.
      "--ro-bind-try"
      "/run/current-system"
      "/run/current-system"
      # Keeps the booted generation resolving after a rebuild.
      "--ro-bind-try"
      "/run/booted-system"
      "/run/booted-system"
      "--ro-bind"
      "/etc"
      "/etc"
    ]
    ++ lib.optionals hasNetwork [
      "--ro-bind-try"
      "/run/systemd/resolve"
      "/run/systemd/resolve"
    ]
    ++ lib.optionals cfg.sysfs (
      lib.concatMap (d: [
        "--ro-bind-try"
        d
        d
      ]) sysfsDirs
      # Interface names and MACs are stable identifiers libdrm never needs.
      ++ [
        "--tmpfs"
        "/sys/class/net"
      ]
    )
    ++ lib.optionals cfg.gpu [
      "--dev-bind-try"
      "/dev/dri"
      "/dev/dri"
      "--ro-bind-try"
      "/run/opengl-driver"
      "/run/opengl-driver"
      "--ro-bind-try"
      "/run/opengl-driver-32"
      "/run/opengl-driver-32"
    ]
    ++ [
      "--setenv"
      "PATH"
      "${package}/bin:/run/current-system/sw/bin"
    ];

  launcher = writeShellApplication {
    name = "confine-${name}";
    runtimeInputs = [
      bubblewrap
      coreutils
    ]
    ++ lib.optional useProxy xdg-dbus-proxy
    ++ lib.optional useA11y dbus
    ++ lib.optional useWaylandProxy wayland-proxy-virtwl
    ++ lib.optional isolatedX11 xwayland-satellite
    ++ lib.optionals isolatedNetwork [
      passt
      iproute2
      gnused
    ];

    text = ''
      target=$1
      shift

      if [ -z "''${HOME:-}" ]; then
        echo "confine: HOME is unset, refusing to guess where the sandbox lives" >&2
        exit 1
      fi

      runtime_dir=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
      instance_id=$$
      instance="$runtime_dir/confine/${appId}.$instance_id"
      flatpak_dir="$runtime_dir/.flatpak/$instance_id"
      # A pid can be reused, clear anything a previous run left behind.
      rm -rf "$instance"
      mkdir -p "$instance"
      chmod 700 "$instance"

      proxy_pid=""
      satellite_pid=""
      wayland_proxy_pid=""
      launch_pid=""
      # shellcheck disable=SC2329 # reached through the traps below
      cleanup() {
        for pid in "$proxy_pid" "$satellite_pid" "$wayland_proxy_pid" "$launch_pid"; do
          if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
          fi
        done
        rm -rf "$instance" "$flatpak_dir"
        ${lib.optionalString useWaylandProxy ''
          # The proxy socket lives in the runtime dir, not the instance dir.
          rm -f "$runtime_dir/confine-${appId}.$instance_id"
        ''}
      }
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM

      ${lib.optionalString (isolatedNetwork && cfg.portals) ''
        # pasta adds a PID namespace, so the child-pid bwrap reports means
        # nothing on the host. Match descendants by mnt namespace inode instead.
        resolve_host_pid() {
          local info="$flatpak_dir/bwrapinfo.json" want frontier next pid kid _try
          want=$(sed -n 's/.*"mnt-namespace": *\([0-9]*\).*/\1/p' "$info")
          [ -n "$want" ] || return 1

          for _try in $(seq 40); do
            frontier=$launch_pid
            for _ in 1 2 3 4 5 6; do
              next=""
              for pid in $frontier; do
                if [ "$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)" = "mnt:[$want]" ]; then
                  sed -i "s/\"child-pid\": *[0-9]*/\"child-pid\": $pid/" "$info"
                  return 0
                fi
                kid=$(cat "/proc/$pid/task/$pid/children" 2>/dev/null) || kid=""
                next="$next $kid"
              done
              frontier=$next
              [ -n "''${frontier// /}" ] || break
            done
            sleep 0.025
          done

          # Better no file than a pid the portal resolves to another process.
          rm -f "$info"
          return 1
        }
      ''}

      ${lib.optionalString cfg.portals ''
        # xdg-desktop-portal reads /proc/<peer>/root/.flatpak-info, and the bus
        # peer it sees is the proxy, so the proxy needs this before starting.
        printf '[Application]\nname=%s\n\n[Instance]\ninstance-id=%s\nsession-bus-proxy=%s\nsystem-bus-proxy=%s\n' \
          ${lib.escapeShellArg appId} "$instance_id" \
          ${lib.escapeShellArg (lib.boolToString useProxy)} \
          ${lib.escapeShellArg (lib.boolToString (useProxy && useSystemBus))} \
          > "$instance/flatpak-info"
      ''}

      args=(${lib.escapeShellArgs staticArgs})

      # Masks only land on existing paths, the /etc bind is read-only.
      ${lib.concatMapStrings (f: ''
        if [ -f ${lib.escapeShellArg f} ]; then
          args+=(--ro-bind /dev/null ${lib.escapeShellArg f})
        fi
      '') maskedFiles}
      ${lib.concatMapStrings (d: ''
        if [ -d ${lib.escapeShellArg d} ]; then
          args+=(--tmpfs ${lib.escapeShellArg d})
        fi
      '') maskedDirs}

      # --clearenv strips everything, a missing var crashes deep inside GTK or Qt.
      # Host plugin trees (QT_PLUGIN_PATH, GTK_PATH, QML2_IMPORT_PATH) stay out,
      # mismatched toolkit plugins crash apps. GIO_EXTRA_MODULES stays out so
      # GSettings falls back to the keyfile backend inside the sandbox.
      for var in TERM LANG LOCALE_ARCHIVE TZDIR TERMINFO_DIRS \
                 XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP \
                 DESKTOP_SESSION XDG_CONFIG_DIRS XDG_MENU_PREFIX \
                 XCURSOR_THEME XCURSOR_SIZE XCURSOR_PATH GTK_THEME \
                 QT_QPA_PLATFORMTHEME QT_STYLE_OVERRIDE QT_WAYLAND_RECONNECT \
                 KDE_FULL_SESSION KDE_SESSION_VERSION \
                 GDK_PIXBUF_MODULE_FILE _JAVA_AWT_WM_NONREPARENTING \
                 XKB_DEFAULT_LAYOUT XKB_DEFAULT_VARIANT XKB_DEFAULT_MODEL \
                 XKB_DEFAULT_OPTIONS XKB_DEFAULT_RULES \
                 SSL_CERT_FILE NIX_SSL_CERT_FILE \
                 NIXOS_OZONE_WL ELECTRON_OZONE_PLATFORM_HINT \
                 ''${!LC_@}; do
        value=''${!var:-}
        if [ -n "$value" ]; then
          args+=(--setenv "$var" "$value")
        fi
      done

      ${lib.optionalString cfg.gpu ''
        # Multi GPU host policy: the session env pins the default card and offload
        # wrappers override it per command. Stripped, Vulkan apps see every card.
        for var in __EGL_VENDOR_LIBRARY_FILENAMES VK_LOADER_DRIVERS_DISABLE \
                   VK_DRIVER_FILES VK_ICD_FILENAMES LIBVA_DRIVER_NAME DRI_PRIME \
                   __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME \
                   __VK_LAYER_NV_optimus; do
          value=''${!var:-}
          if [ -n "$value" ]; then
            args+=(--setenv "$var" "$value")
          fi
        done
      ''}

      ${lib.optionalString (cfg.envPassthrough != [ ]) ''
        # App declared copies of host vars whose value is only known at launch.
        for var in ${lib.escapeShellArgs cfg.envPassthrough}; do
          value=''${!var:-}
          if [ -n "$value" ]; then
            args+=(--setenv "$var" "$value")
          fi
        done
      ''}

      args+=(
        --setenv HOME "$HOME"
        --setenv USER "''${USER:-$(id -un)}"
        --setenv LOGNAME "''${LOGNAME:-$(id -un)}"
        --setenv XDG_RUNTIME_DIR "$runtime_dir"
        --setenv XDG_DATA_DIRS "${package}/share:''${XDG_DATA_DIRS:-/run/current-system/sw/share}"
      )

      ${
        if cfg.runtimeDir == "shared" then
          ''
            # bind(2) refuses to create a socket at a name that exists, symlinks
            # included, so a server's socket can only be shared by backing the
            # directory it writes to with a host one.
            mkdir -p "$runtime_dir/app/${appId}"
            chmod 700 "$runtime_dir/app/${appId}"
            args+=(--bind "$runtime_dir/app/${appId}" "$runtime_dir")
          ''
        else
          ''
            args+=(--dir "$runtime_dir" --chmod 0700 "$runtime_dir")
          ''
      }

      # Last, the final --setenv wins in bwrap and declared env outranks host values.
      args+=(${lib.escapeShellArgs (
        lib.concatMap (n: [
          "--setenv"
          n
          cfg.env.${n}
        ]) (lib.attrNames cfg.env)
      )})

      # The per-app runtime dir Flatpak apps expect, single-instance locks and
      # RPC sockets live here. Shared across instances, so kept on exit.
      mkdir -p "$runtime_dir/app/${appId}"
      # The default umask would leave per-app state readable by other apps.
      chmod 700 "$runtime_dir/app/${appId}"
      args+=(--bind "$runtime_dir/app/${appId}" "$runtime_dir/app/${appId}")

      ${
        if homeMode == "private" then
          ''
            private_home=''${XDG_DATA_HOME:-$HOME/.local/share}/confine/${appId}
            mkdir -p "$private_home"
            args+=(--bind "$private_home" "$HOME")
          ''
        else if homeMode == "ephemeral" then
          ''
            # A dir on the sandbox root, writable and gone on exit.
            args+=(--dir "$HOME")
          ''
        else
          ''
            args+=(--bind "$HOME" "$HOME")
          ''
      }

      ${lib.optionalString (cfg.binds.ro != [ ] || cfg.binds.rw != [ ]) ''
        # Relative paths resolve against the real home, xdg-run/ against the
        # runtime directory.
        add_bind() {
          local mode=$1 from=$2 to=$3 src dest
          case "$from" in
            xdg-run/*) src="$runtime_dir/''${from#xdg-run/}" ;;
            /*) src="$from" ;;
            *)  src="$HOME/$from" ;;
          esac
          case "$to" in
            xdg-run/*) dest="$runtime_dir/''${to#xdg-run/}" ;;
            /*) dest="$to" ;;
            *)  dest="$HOME/$to" ;;
          esac

          # Absolute paths are never created, that would paper over an unmounted disk.
          if [ "$mode" = rw ]; then
            case "$from" in
              /*) : ;;
              *)  mkdir -p "$src" ;;
            esac
            args+=(--bind-try "$src" "$dest")
          else
            args+=(--ro-bind-try "$src" "$dest")
          fi
        }

        ${lib.concatMapStrings (b: ''
          add_bind ro ${lib.escapeShellArg b.from} ${lib.escapeShellArg b.to}
        '') (map normaliseBind cfg.binds.ro)}
        ${lib.concatMapStrings (b: ''
          add_bind rw ${lib.escapeShellArg b.from} ${lib.escapeShellArg b.to}
        '') (map normaliseBind cfg.binds.rw)}
      ''}

      ${lib.optionalString (cfg.symlinks != [ ]) ''
        # connect(2) follows these, so they reach a socket in a bound directory.
        add_symlink() {
          local target=$1 link=$2 dest
          case "$link" in
            xdg-run/*) dest="$runtime_dir/''${link#xdg-run/}" ;;
            /*) dest="$link" ;;
            *)  dest="$HOME/$link" ;;
          esac
          args+=(--symlink "$target" "$dest")
        }

        ${lib.concatMapStrings (s: ''
          add_symlink ${lib.escapeShellArg s.target} ${lib.escapeShellArg s.link}
        '') cfg.symlinks}
      ''}

      ${lib.optionalString (cfg.devices != [ ]) ''
        add_devices() {
          local pattern=$1 dev matches
          # nullglob so an unmatched pattern expands to nothing.
          shopt -s nullglob
          # shellcheck disable=SC2206 # the pattern is a glob on purpose
          matches=($pattern)
          shopt -u nullglob
          for dev in ''${matches[@]+"''${matches[@]}"}; do
            if [ -e "$dev" ]; then
              args+=(--dev-bind "$dev" "$dev")
            fi
          done
        }

        ${lib.concatMapStrings (p: ''
          add_devices ${lib.escapeShellArg p}
        '') cfg.devices}
      ''}

      ${lib.optionalString cfg.sysfs ''
        # /sys/class/net is only symlinks, the real net dirs sit in /sys/devices.
        while IFS= read -r netdir; do
          args+=(--tmpfs "$netdir")
        done < <(find /sys/devices -maxdepth 8 -type d -name net 2>/dev/null)
      ''}

      ${lib.optionalString cfg.gpu ''
        for node in /dev/nvidia*; do
          if [ -e "$node" ]; then
            args+=(--dev-bind "$node" "$node")
          fi
        done
      ''}

      ${lib.optionalString (cfg.wayland || isolatedX11) ''
        host_wayland_socket=$(basename "''${WAYLAND_DISPLAY:-wayland-0}")
        if [ ! -S "$runtime_dir/$host_wayland_socket" ]; then
          echo "confine: no wayland socket at $runtime_dir/$host_wayland_socket" >&2
          exit 1
        fi
        wayland_socket=$host_wayland_socket
      ''}

      ${lib.optionalString useWaylandProxy ''
        # Withholds zwlr_data_control_manager_v1, unfocused clipboard reads that
        # KWin's blacklist misses. Opt-in, it also drops fractional scaling.
        wayland_socket=confine-${appId}.$instance_id
        wayland-proxy-virtwl --wayland-display="$wayland_socket" &
        wayland_proxy_pid=$!

        for _ in $(seq 200); do
          if [ -S "$runtime_dir/$wayland_socket" ]; then break; fi
          sleep 0.025
        done
        if [ ! -S "$runtime_dir/$wayland_socket" ]; then
          echo "confine: the wayland proxy never came up" >&2
          exit 1
        fi
      ''}

      ${lib.optionalString cfg.wayland ''
        # No security-context, KWin's allowInterface() (wayland_server.cpp)
        # already refuses fake_input without X-KDE-Wayland-Interfaces.
        args+=(
          --ro-bind "$runtime_dir/$wayland_socket" "$runtime_dir/$wayland_socket"
          --setenv WAYLAND_DISPLAY "$wayland_socket"
        )
      ''}

      ${lib.optionalString isolatedX11 ''
        # The host X server would let the app read every window's keystrokes.
        # --unshare-net matters, abstract X sockets are scoped by network namespace.
        x11_dir="$instance/X11"
        mkdir -p "$x11_dir"

        satellite_args=(
          --unshare-user --unshare-ipc --unshare-pid --unshare-net
          --unshare-uts --unshare-cgroup-try
          --new-session --die-with-parent
          --proc /proc --dev /dev --tmpfs /tmp
          --ro-bind /nix/store /nix/store
          --ro-bind-try /run/current-system /run/current-system
          --ro-bind /etc /etc
          --dir "$runtime_dir"
          --ro-bind "$runtime_dir/$host_wayland_socket" "$runtime_dir/$host_wayland_socket"
          --bind "$x11_dir" /tmp/.X11-unix
          --setenv XDG_RUNTIME_DIR "$runtime_dir"
          --setenv WAYLAND_DISPLAY "$host_wayland_socket"
          --unsetenv DISPLAY
        )

        ${lib.optionalString cfg.gpu ''
          # Without the GPU Xwayland falls back to software and offers no GLX visual.
          satellite_args+=(
            --dev-bind-try /dev/dri /dev/dri
            --ro-bind-try /run/opengl-driver /run/opengl-driver
            --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32
            ${lib.concatMapStringsSep "\n            " (d: "--ro-bind-try ${d} ${d}") sysfsDirs}
          )
        ''}

        bwrap "''${satellite_args[@]}" -- xwayland-satellite :99 &
        satellite_pid=$!

        for _ in $(seq 200); do
          if [ -S "$x11_dir/X99" ]; then break; fi
          sleep 0.025
        done
        if [ ! -S "$x11_dir/X99" ]; then
          echo "confine: xwayland-satellite never came up" >&2
          exit 1
        fi

        args+=(--bind "$x11_dir" /tmp/.X11-unix --setenv DISPLAY :99)
      ''}

      ${lib.optionalString (cfg.x11 == "host") ''
        if [ -n "''${DISPLAY:-}" ]; then
          display_num=''${DISPLAY#*:}
          display_num=''${display_num%%.*}
          if [ -S "/tmp/.X11-unix/X$display_num" ]; then
            args+=(
              --ro-bind "/tmp/.X11-unix/X$display_num" "/tmp/.X11-unix/X$display_num"
              --setenv DISPLAY "$DISPLAY"
            )
          fi
          if [ -n "''${XAUTHORITY:-}" ] && [ -e "$XAUTHORITY" ]; then
            args+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY" --setenv XAUTHORITY "$XAUTHORITY")
          fi
        fi
      ''}

      ${lib.optionalString cfg.pipewire ''
        # The -manager socket can rewire the graph and tap other apps' audio.
        for sock in "$runtime_dir"/pipewire-[0-9]; do
          if [ -S "$sock" ]; then
            args+=(--ro-bind "$sock" "$sock")
          fi
        done
      ''}

      ${lib.optionalString cfg.pulse ''
        # libpulse chmods $XDG_RUNTIME_DIR/pulse and fails when it is a bind
        # target. enable-shm=no, shm needs a shared /dev/shm and IPC namespace.
        if [ -S "$runtime_dir/pulse/native" ]; then
          # Not --ro-bind-data, that takes a descriptor and pasta closes inherited fds.
          printf 'enable-shm=no\n' > "$instance/pulse-config"
          args+=(
            --dir /run/flatpak/pulse
            --ro-bind "$runtime_dir/pulse/native" /run/flatpak/pulse/native
            --ro-bind "$instance/pulse-config" /run/flatpak/pulse/config
            --symlink ../../flatpak/pulse "$runtime_dir/pulse"
            --setenv PULSE_SERVER unix:/run/flatpak/pulse/native
            --setenv PULSE_CLIENTCONFIG /run/flatpak/pulse/config
          )
        fi
      ''}

      ${
        if useProxy then
          ''
            session_bus=''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}
            mkfifo -m 600 "$instance/sync"

            proxy_args=(--fd=3 "$session_bus" "$instance/session-bus" ${lib.escapeShellArgs sessionProxyArgs})
            ${lib.optionalString useSystemBus ''
              proxy_args+=(unix:path=/run/dbus/system_bus_socket "$instance/system-bus" ${lib.escapeShellArgs systemProxyArgs})
            ''}
            ${lib.optionalString useA11y ''
              # xdg-dbus-proxy takes several bus triples in one invocation.
              a11y_address=''${AT_SPI_BUS_ADDRESS:-}
              if [ -z "$a11y_address" ]; then
                a11y_address=$(dbus-send --session --print-reply=literal \
                  --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress 2>/dev/null \
                  | tr -d '[:space:]') || a11y_address=""
              fi
              if [ -n "$a11y_address" ]; then
                proxy_args+=("$a11y_address" "$instance/a11y-bus" ${lib.escapeShellArgs a11yProxyArgs})
              fi
            ''}
            proxy_wrapper=()
            ${lib.optionalString cfg.portals ''
              # The portal inspects the bus peer, the proxy, so the forged
              # /.flatpak-info must sit in the proxy's own namespace.
              proxy_wrapper=(
                bwrap --die-with-parent --clearenv --new-session
                --proc /proc --dev /dev
                --ro-bind /nix/store /nix/store
                --ro-bind /etc /etc
                --bind "$runtime_dir" "$runtime_dir"
                --ro-bind-try /run/dbus /run/dbus
                --ro-bind "$instance/flatpak-info" /.flatpak-info
                --
              )
            ''}
            # Absolute path, the wrapper above clears PATH.
            ''${proxy_wrapper[@]+"''${proxy_wrapper[@]}"} \
              ${xdg-dbus-proxy}/bin/xdg-dbus-proxy "''${proxy_args[@]}" 3>"$instance/sync" &
            proxy_pid=$!

            # The proxy writes one byte on --fd when ready and exits when that
            # fd closes, so the read end is held for the whole run.
            exec {sync_fd}<"$instance/sync"
            read -r -N 1 -t 10 -u "$sync_fd" _ready || true

            if [ ! -S "$instance/session-bus" ]; then
              echo "confine: the D-Bus proxy never came up" >&2
              exit 1
            fi

            args+=(
              --ro-bind "$instance/session-bus" "$runtime_dir/bus"
              --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$runtime_dir/bus"
            )
            ${lib.optionalString useSystemBus ''
              args+=(--ro-bind "$instance/system-bus" /run/dbus/system_bus_socket)
            ''}
            ${lib.optionalString useA11y ''
              if [ -S "$instance/a11y-bus" ]; then
                args+=(
                  --ro-bind "$instance/a11y-bus" /run/flatpak/at-spi-bus
                  --setenv AT_SPI_BUS_ADDRESS unix:path=/run/flatpak/at-spi-bus
                )
              fi
            ''}
          ''
        else
          ''
            if [ -S "$runtime_dir/bus" ]; then
              args+=(
                --ro-bind "$runtime_dir/bus" "$runtime_dir/bus"
                --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$runtime_dir/bus"
              )
            fi
          ''
      }

      ${lib.optionalString cfg.portals ''
        # Only this app's slice, the top level doc dir holds every app's grants.
        mkdir -p "$runtime_dir/doc/by-app/${appId}" 2>/dev/null || true

        args+=(
          --ro-bind "$instance/flatpak-info" /.flatpak-info
          --bind-try "$runtime_dir/doc/by-app/${appId}" "$runtime_dir/doc"
        )
      ''}

      ${lib.optionalString cfg.seccomp.enable ''
        export CONFINE_FILTER=${filter}
      ''}

      ${lib.optionalString cfg.portals ''
        args+=(--info-fd 4)
        export CONFINE_INFO="$instance/info"
      ''}

      ${lib.optionalString isolatedNetwork ''
        # pasta maps the caller to uid 0 and Chromium refuses to run as root.
        args+=(--uid "$(id -u)" --gid "$(id -g)")

        # Forwards default to "auto", exposing every loopback service, so they
        # start closed. --no-map-gw and the outbound pin close the other routes.
        pasta_args=(
          --config-net --no-map-gw --quiet
          -t ${portSpec cfg.networkPorts.fromHost} -u ${portSpec cfg.networkPorts.fromHost}
          -T ${portSpec cfg.networkPorts.toHost}   -U ${portSpec cfg.networkPorts.toHost}
          ${lib.escapeShellArgs cfg.extraPastaArgs}
        )
        route_if=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
        if [ -n "$route_if" ]; then
          pasta_args+=(--outbound-if4 "$route_if")
        fi
        route_if6=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
        if [ -n "$route_if6" ]; then
          pasta_args+=(--outbound-if6 "$route_if6")
        fi
      ''}

      # Last so extraBwrapArgs can override anything generated above.
      args+=(${lib.escapeShellArgs cfg.extraBwrapArgs})

      # shellcheck disable=SC2016 # the inner script must not expand out here
      launch=(${runtimeShell} -c ${lib.escapeShellArg innerScript} confine
              "''${args[@]}" -- "$target" "$@")

      ${lib.optionalString isolatedNetwork ''
        launch=(pasta "''${pasta_args[@]}" -- "''${launch[@]}")
      ''}

      ${
        if cfg.portals then
          ''
            # The portal resolves instance-id to bwrapinfo.json and opens a pidfd
            # on child-pid. Since 1.19 a missing file fails the whole lookup.
            mkdir -p "$flatpak_dir"
            mkfifo -m 600 "$instance/info"

            "''${launch[@]}"${closeSyncFd} &
            launch_pid=$!

            # The fifo blocks until bwrap opens it, timeout guards a chain that died first.
            if ! timeout 10 cat "$instance/info" > "$flatpak_dir/bwrapinfo.json"; then
              echo "confine: the sandbox never started" >&2
              exit 1
            fi
            ${lib.optionalString isolatedNetwork ''
              resolve_host_pid || echo "confine: could not resolve the sandbox pid, portals may not identify this app" >&2
            ''}

            status=0
            wait "$launch_pid" || status=$?
            exit "$status"
          ''
        else
          ''
            "''${launch[@]}"${closeSyncFd}
          ''
      }
    '';
  };

  binaryList =
    if cfg.binaries == null then ''$(cd "${package}/bin" && ls)'' else lib.escapeShellArgs cfg.binaries;

  # "sandbox-" reads as "sandbox" in menu entry names.
  binPrefixLabel =
    let
      m = builtins.match "(.*[A-Za-z0-9])[-_.]*" cfg.binPrefix;
    in
    if m == null then cfg.binPrefix else lib.head m;
in

checked (runCommand "${name}-confined"
  {
    # outputsToInstall would name outputs the single-output wrapper lacks.
    meta =
      removeAttrs (package.meta or { }) [ "outputsToInstall" ]
      // lib.optionalAttrs (cfg.binPrefix != "" && package.meta ? mainProgram) {
        mainProgram = cfg.binPrefix + package.meta.mainProgram;
      };
    passthru = (package.passthru or { }) // {
      inherit filter launcher;
      unwrapped = package;
      permissions = cfg;

      # Overriding re-confines so programs.steam cannot return an unconfined
      # build. setFunctionArgs keeps the signature lib.functionArgs callers see.
      override = lib.setFunctionArgs (
        f: confineAgain (package.override f)
      ) (lib.functionArgs (package.override or (x: x)));

      overrideAttrs = f: confineAgain (package.overrideAttrs f);
      # The rules the proxy enforces, with the app's own names folded in.
      dbusArgs = {
        session = sessionProxyArgs;
        system = systemProxyArgs;
      };
    };
  }
  ''
    mkdir -p "$out/bin"

    # The held back trees all contain launch paths of their own.
    for entry in ${package}/*; do
      case "$(basename "$entry")" in
        bin|share|etc) ;;
        *) ln -s "$entry" "$out/$(basename "$entry")" ;;
      esac
    done

    if [ -d ${package}/share ]; then
      mkdir -p "$out/share"
      for entry in ${package}/share/*; do
        case "$(basename "$entry")" in
          applications|dbus-1|systemd) ;;
          *) ln -s "$entry" "$out/share/$(basename "$entry")" ;;
        esac
      done
    fi

    # foot keeps terminfo in a separate output, losing it breaks terminals
    # inside. Only the top level merges, nested collisions still lose files.
    ${lib.concatMapStrings (o: ''
      if [ -d ${package.${o}}/share ]; then
        mkdir -p "$out/share"
        for entry in ${package.${o}}/share/*; do
          target="$out/share/$(basename "$entry")"
          [ -e "$target" ] || ln -s "$entry" "$target"
        done
      fi
    '') (lib.filter (o: o != "out" && o != "debug" && package ? ${o}) (package.outputs or [ ]))}

    # A service file naming the original binary would launch it unconfined.
    rewrite_launchers() {
      local src=$1 dest=$2 entry
      [ -d "$src" ] || return 0
      mkdir -p "$dest"
      for entry in "$src"/*; do
        if [ -d "$entry" ]; then
          rewrite_launchers "$entry" "$dest/$(basename "$entry")"
        elif [ -f "$entry" ]; then
          sed "s|${package}/bin/|$out/bin/${cfg.binPrefix}|g" "$entry" > "$dest/$(basename "$entry")"
        fi
      done
    }
    rewrite_launchers ${package}/share/dbus-1 "$out/share/dbus-1"
    rewrite_launchers ${package}/share/systemd "$out/share/systemd"
    rewrite_launchers ${package}/etc "$out/etc"

    binaries=(${binaryList})

    for bin in "''${binaries[@]}"; do
      if [ ! -e "${package}/bin/$bin" ]; then
        echo "confine: ${package} has no bin/$bin" >&2
        exit 1
      fi
      printf '#!%s\nexec %s %s "$@"\n' \
        ${runtimeShell} ${launcher}/bin/${launcher.name} "${package}/bin/$bin" \
        > "$out/bin/${cfg.binPrefix}$bin"
      chmod +x "$out/bin/${cfg.binPrefix}$bin"
    done

    # Launchers must reach the wrapper, never the store path behind it.
    if [ -d ${package}/share/applications ]; then
      mkdir -p "$out/share/applications"
      entries=(${package}/share/applications/*.desktop)

      for desktop in "''${entries[@]}"; do
        # Portals resolve the app id to a matching .desktop for name and icon,
        # so a lone entry is renamed to the forged id.
        if [ "''${#entries[@]}" -eq 1 ]; then
          dest="$out/share/applications/${appId}.desktop"
        else
          dest="$out/share/applications/$(basename "$desktop")"
        fi

        cp "$desktop" "$dest"
        chmod +w "$dest"
        for bin in "''${binaries[@]}"; do
          # '#' delimits because the pattern itself alternates on '|'.
          sed -i -E "s#^(Exec|TryExec)=([^ ]*/)?$bin([[:space:]]|\$)#\1=$out/bin/${cfg.binPrefix}$bin\3#" "$dest"
        done
        ${lib.optionalString (cfg.binPrefix != "") ''
          # Tells the confined menu entry apart from the unconfined one.
          sed -i "0,/^Name=/s/^Name=\(.*\)/Name=\1 (${binPrefixLabel})/" "$dest"
        ''}
      done
    fi
  '')
)
