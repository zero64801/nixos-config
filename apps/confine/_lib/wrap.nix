{
  lib,
  callPackage,
  runCommand,
  runtimeShell,
  writeShellApplication,
  bubblewrap,
  coreutils,
  dbus,
  findutils,
  gnugrep,
  flatpak-xdg-utils,
  getent,
  gnused,
  iproute2,
  passt,
  systemd,
  wayland-proxy-virtwl,
  xdg-dbus-proxy,
  xwayland-satellite,
}:

let
  mkFilter = callPackage ./seccomp.nix { };
  securityContext = callPackage ./security-context.nix { };
  helpers = callPackage ./helpers.nix { };
  profiles = import ./profiles.nix;

  defaults = {
    name = null;
    binaries = null;
    binPrefix = "";
    keepDesktopNames = false;
    profile = [ ];
    network = false;
    wayland = false;
    waylandProxy = false;
    waylandSecurityContext = true;
    waylandAppId = null;
    x11 = "none";
    pipewire = false;
    pulse = false;
    gpu = false;
    sysfs = false;
    portals = false;
    a11y = false;
    home = "private";
    hostAccounts = false;
    devices = [ ];
    securityKeys = false;
    binds = {
      ro = [ ];
      rw = [ ];
    };
    symlinks = [ ];
    runtimeDir = "private";
    workdir = null;
    gitGuard = {
      enable = false;
      depth = 4;
    };
    scope = true;
    resources = { };
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
    networkSetups = { };
    seccomp = {
      enable = true;
      nesting = false;
      multiarch = false;
      devel = false;
      bluetooth = false;
      can = false;
      ioUring = false;
    };
    extraBwrapArgs = [ ];
  };

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

  # Host-only identity and credentials that a readable /etc would otherwise hand over.
  maskedFiles = [
    "/etc/shadow"
    "/etc/gshadow"
    "/etc/subuid"
    "/etc/subgid"
    "/etc/u2f_keys"
    "/etc/nix/netrc"
  ];
  maskedDirs = [ "/etc/ssh" ];

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

  isPattern = b: lib.isString b && builtins.match ".*[*?[].*" b != null;

  xdgNames = [
    "xdg-desktop"
    "xdg-documents"
    "xdg-download"
    "xdg-music"
    "xdg-pictures"
    "xdg-public-share"
    "xdg-videos"
    "xdg-templates"
    "xdg-config"
    "xdg-cache"
    "xdg-data"
    "xdg-state"
  ];
  bindPath = b: if lib.isString b then b else b.from;
  knownXdg = p: !(lib.hasPrefix "xdg-" p) || lib.hasPrefix "xdg-run/" p || lib.elem (lib.head (lib.splitString "/" p)) xdgNames;

  xdgPortalOpen = runCommand "confine-xdg-open" { } ''
    mkdir -p $out/bin
    ln -s ${flatpak-xdg-utils}/bin/xdg-open $out/bin/xdg-open
    ln -s ${flatpak-xdg-utils}/bin/xdg-email $out/bin/xdg-email
  '';

  ownedNames = id: [
    id
    "${id}.*"
    "org.mpris.MediaPlayer2.${id}.*"
  ];
in

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
    else if
      lib.any (v: !lib.isString v || builtins.match "[A-Za-z_][A-Za-z0-9_]*" v == null)
        cfg.envPassthrough
    then
      throw "confine: envPassthrough entries must be environment variable names"
    else if !lib.isString cfg.binPrefix || builtins.match "[A-Za-z0-9_.-]*" cfg.binPrefix == null then
      throw "confine: binPrefix may only contain letters, digits, dot, dash and underscore"
    else if
      cfg.waylandAppId != null
      && (!lib.isString cfg.waylandAppId || builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" cfg.waylandAppId == null)
    then
      throw "confine: waylandAppId must be a plain application id, not ${builtins.toJSON cfg.waylandAppId}"
    else if lib.any (b: isPattern b && builtins.match ".*[[:space:]].*" b != null) (cfg.binds.ro ++ cfg.binds.rw) then
      throw "confine: bind patterns cannot contain whitespace"
    else if lib.any (b: !lib.isString b && (isPattern b.from || isPattern b.to)) (cfg.binds.ro ++ cfg.binds.rw) then
      throw "confine: bind patterns must be plain strings, each match is bound at its own path"
    else if !lib.all (s: s ? link && s ? target && lib.isString s.link && lib.isString s.target) cfg.symlinks then
      throw "confine: symlinks entries must be { link, target } string pairs"
    else if !lib.elem cfg.workdir [ null "ro" "rw" ] then
      throw "confine: workdir must be null, ro or rw, not ${builtins.toJSON cfg.workdir}"
    else if !lib.elem cfg.runtimeDir [ "private" "shared" ] then
      throw "confine: runtimeDir must be private or shared, not ${builtins.toJSON cfg.runtimeDir}"
    else if !lib.all (b: knownXdg (bindPath b) && (lib.isString b || knownXdg b.to)) (cfg.binds.ro ++ cfg.binds.rw) then
      throw "confine: unknown xdg- location in binds, known are xdg-run/ and ${lib.concatStringsSep ", " xdgNames}"
    else if !lib.isInt cfg.gitGuard.depth || cfg.gitGuard.depth < 1 || cfg.gitGuard.depth > 8 then
      throw "confine: gitGuard.depth must be an integer from 1 to 8"
    else if lib.any (k: builtins.match "[A-Z][A-Za-z]+" k == null) (lib.attrNames cfg.resources) then
      throw "confine: resources are systemd property names such as MemoryMax or CPUWeight"
    else if lib.any (v: !(lib.isInt v || (lib.isString v && builtins.match "[^\n]+" v != null))) (lib.attrValues cfg.resources) then
      throw "confine: resources values must be integers or single-line strings"
    else if lib.any (n: builtins.match "[A-Za-z0-9_-]+" n == null) (lib.attrNames cfg.networkSetups) then
      throw "confine: networkSetups names may only contain letters, digits, dash and underscore"
    else if cfg.networkSetups != { } && !isolatedNetwork then
      throw "confine: networkSetups need network = \"isolated\", they run inside pasta's namespace"
    else
      x: x;
  name = if cfg.name != null then cfg.name else package.pname or package.name;
  version = package.version or "";
  confinedName = "${name}-confined" + lib.optionalString (version != "") "-${version}";

  networkMode =
    if lib.isBool cfg.network then
      (if cfg.network then "host" else "none")
    else if lib.elem cfg.network [ "none" "host" "isolated" ] then
      cfg.network
    else
      throw "confine: network must be none, host or isolated, not ${toString cfg.network}";

  isolatedNetwork = networkMode == "isolated";
  hasNetwork = networkMode != "none";

  homeMode =
    if lib.elem cfg.home [ "private" "ephemeral" "host" ] then
      cfg.home
    else
      throw "confine: home must be private, ephemeral or host, not ${builtins.toJSON cfg.home}";

  unknownKeys = lib.subtractLists (lib.attrNames defaults ++ [ "package" "appId" ]) (
    lib.attrNames settings
  );

  portSpec =
    ports:
    if ports == [ ] then
      "none"
    else if lib.all (p: lib.isInt p || lib.isString p) ports then
      lib.concatMapStringsSep "," toString ports
    else
      throw "confine: networkPorts entries must be integers or pasta port specs";

  filter = mkFilter {
    inherit (cfg.seccomp)
      nesting
      multiarch
      devel
      bluetooth
      can
      ioUring
      ;
  };

  useSystemBus = cfg.dbus.system.talk != [ ] || cfg.dbus.system.call != [ ];
  useProxy = cfg.dbus.filter;
  isolatedX11 = cfg.x11 == "isolated";

  # pasta closes inherited descriptors, so the filter and info fds open on its far side, after the setup so nothing it leaves running holds them.
  innerScript =
    lib.optionalString (cfg.networkSetups != { }) ''
      if [ -n "''${CONFINE_NETWORK_SETUP_BIN:-}" ]; then
        "$CONFINE_NETWORK_SETUP_BIN" || exit 1
      fi
    ''
    + lib.optionalString cfg.seccomp.enable ''
      exec {confine_seccomp_fd}<"$CONFINE_FILTER"
    ''
    + "exec bwrap "
    + lib.optionalString cfg.seccomp.enable "--seccomp \"$confine_seccomp_fd\" "
    + "\"$@\" 4>\"$CONFINE_INFO\"";

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
  useSecurityContext = cfg.waylandSecurityContext && (cfg.wayland || isolatedX11);
  needsGuard = cfg.binds.ro != [ ] || cfg.gitGuard.enable;
  usesXdgNames = lib.any (
    b: lib.hasPrefix "xdg-" (bindPath b) && !lib.hasPrefix "xdg-run/" (bindPath b)
  ) (cfg.binds.ro ++ cfg.binds.rw);
  resourceArgs = lib.concatMapStringsSep " " (
    k: "-p ${lib.escapeShellArg "${k}=${toString cfg.resources.${k}}"}"
  ) (lib.attrNames cfg.resources);
  contextAppId = if cfg.waylandAppId != null then cfg.waylandAppId else appId;

  staticArgs =
    [ "--unshare-all" ]
    # In isolated mode this keeps pasta's namespace rather than the host's.
    ++ lib.optional hasNetwork "--share-net"
    # The kernel half of the namespace lock, so a gap in the seccomp half cannot give the app a mount table of its own, the pairing Flatpak uses.
    ++ lib.optionals (!cfg.seccomp.nesting) [
      "--unshare-user"
      "--disable-userns"
    ]
    ++ [
      "--die-with-parent"
      "--clearenv"
      "--proc"
      "/proc"
      "--dev"
      "/dev"
      "--tmpfs"
      "/tmp"
      "--tmpfs"
      "/var/tmp"
      "--ro-bind"
      "/nix/store"
      "/nix/store"
      "--ro-bind"
      "/etc"
      "/etc"
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
      "${lib.optionalString cfg.portals "${xdgPortalOpen}/bin:"}${package}/bin:/run/current-system/sw/bin"
    ];

  launcher = writeShellApplication {
    name = "confine-${name}";
    runtimeInputs = [
      bubblewrap
      coreutils
      getent
      gnused
    ]
    ++ lib.optional useProxy xdg-dbus-proxy
    ++ lib.optional (cfg.scope || cfg.gitGuard.enable) systemd
    ++ lib.optional (cfg.gitGuard.enable || cfg.sysfs) findutils
    ++ lib.optional cfg.gitGuard.enable gnugrep
    ++ lib.optional useA11y dbus
    ++ lib.optional useWaylandProxy wayland-proxy-virtwl
    ++ lib.optional isolatedX11 xwayland-satellite
    ++ lib.optionals isolatedNetwork [
      passt
      iproute2
    ];

    text = ''
      target=$1
      shift

      if [ -z "''${HOME:-}" ]; then
        echo "confine: HOME is unset, refusing to guess where the sandbox lives" >&2
        exit 1
      fi

      ${lib.optionalString cfg.scope ''
        # A scope of its own lets the whole app be listed, stopped and limited as one unit, as Flatpak's app-flatpak-*.scope does. A nested launch has no user manager to ask and runs in its parent's.
        if [ -z "''${CONFINE_SCOPE:-}" ] && systemctl --user show --property=Version >/dev/null 2>&1; then
          CONFINE_SCOPE="app-confine-${appId}-$$.scope"
          export CONFINE_SCOPE
          exec systemd-run --user --scope --quiet --collect --unit="$CONFINE_SCOPE" \
            --description=${lib.escapeShellArg "${name} (confined)"} ${resourceArgs} -- "$0" "$target" "$@"
        fi
      ''}

      runtime_dir=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
      mkdir -p "$runtime_dir/confine" ${lib.optionalString cfg.portals ''"$runtime_dir/.flatpak"''}
      # Random ids claimed by an atomic mkdir, as Flatpak allocates its own, so neither another instance nor a real Flatpak sharing .flatpak can collide.
      instance=""
      for _ in $(seq 100); do
        instance_id=$SRANDOM
        if mkdir -m 700 "$runtime_dir/confine/${appId}.$instance_id" 2>/dev/null; then
          ${
            if cfg.portals then
              ''
                if mkdir -m 700 "$runtime_dir/.flatpak/$instance_id" 2>/dev/null; then
                  instance="$runtime_dir/confine/${appId}.$instance_id"
                  break
                fi
                rmdir "$runtime_dir/confine/${appId}.$instance_id"
              ''
            else
              ''
                instance="$runtime_dir/confine/${appId}.$instance_id"
                break
              ''
          }
        fi
      done
      if [ -z "$instance" ]; then
        echo "confine: could not allocate an instance id" >&2
        exit 1
      fi
      flatpak_dir=${if cfg.portals then ''"$runtime_dir/.flatpak/$instance_id"'' else ''""''}

      printf 'app=%s\nname=%s\nlauncher=%s\nlauncher_pid=%s\nscope=%s\nstarted=%s\nfilter=%s\n' \
        ${appId} ${lib.escapeShellArg name} "$0" "$$" "''${CONFINE_SCOPE:-}" "$(date +%s)" \
        ${if cfg.seccomp.enable then "${filter}" else ''""''} > "$instance/state"

      proxy_pid=""
      satellite_pid=""
      wayland_proxy_pid=""
      security_context_pid=""
      info_pid=""
      # shellcheck disable=SC2329 # reached through the traps below
      cleanup() {
        for pid in "$proxy_pid" "$satellite_pid" "$wayland_proxy_pid" "$security_context_pid" "$info_pid"; do
          if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
          fi
        done
        if declare -F audit_git >/dev/null; then
          audit_git || true
        fi
        rm -rf "$instance"
        if [ -n "$flatpak_dir" ]; then
          rm -rf "$flatpak_dir"
        fi
        ${lib.optionalString useWaylandProxy ''
          rm -f "$runtime_dir/confine-${appId}.$instance_id"
        ''}
        ${lib.optionalString useSecurityContext ''
          rm -f "$runtime_dir/confine-${appId}.$instance_id.context"
        ''}
      }
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM

      # Only a declared setup may run outside bwrap, never a path from the environment.
      unset CONFINE_NETWORK_SETUP_BIN
      case "''${CONFINE_NETWORK_SETUP:-}" in
        "") ;;
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            n: setup:
            "${n}) export CONFINE_NETWORK_SETUP_BIN=${lib.escapeShellArg "${setup}"} CONFINE_INSTANCE=\"$instance\" ;;"
          ) cfg.networkSetups
        )}
        *)
          echo "confine: ${appId} has no network setup named $CONFINE_NETWORK_SETUP" >&2
          exit 1
          ;;
      esac

      # bwrap names its first sandboxed process, but pasta puts a pid namespace in between, so the host pid is the process in that mount namespace whose parent is outside it.
      find_sandbox_pid() {
        local want=$1 entry pid parent key value
        for entry in /proc/[0-9]*; do
          pid=''${entry#/proc/}
          [ "$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)" = "mnt:[$want]" ] || continue
          parent=""
          while IFS=$'\t' read -r key value; do
            if [ "$key" = PPid: ]; then
              parent=$value
              break
            fi
          done 2>/dev/null < "/proc/$pid/status" || continue
          if [ -n "$parent" ] && [ "$(readlink "/proc/$parent/ns/mnt" 2>/dev/null)" != "mnt:[$want]" ]; then
            printf '%s' "$pid"
            return 0
          fi
        done
        return 1
      }

      ${lib.optionalString cfg.portals ''
        printf '[Application]\nname=%s\n\n[Instance]\ninstance-id=%s\nsession-bus-proxy=%s\nsystem-bus-proxy=%s\n' \
          ${lib.escapeShellArg appId} "$instance_id" \
          ${lib.escapeShellArg (lib.boolToString useProxy)} \
          ${lib.escapeShellArg (lib.boolToString (useProxy && useSystemBus))} \
          > "$instance/flatpak-info"
      ''}

      args=(${lib.escapeShellArgs staticArgs})

      # A link like the host's, a mounted copy would hide that the running system is a store path.
      for system_link in /run/current-system /run/booted-system; do
        if system_target=$(readlink "$system_link"); then
          args+=(--symlink "$system_target" "$system_link")
        fi
      done

      # Shebangs, system() and popen() expect /bin/sh and /usr/bin/env, kept read-only like Flatpak's /usr so the app cannot swap them.
      for fhs_dir in /bin /usr/bin; do
        fhs_args=()
        for fhs_link in "$fhs_dir"/*; do
          if fhs_target=$(readlink "$fhs_link"); then
            fhs_args+=(--symlink "$fhs_target" "$fhs_link")
          fi
        done
        if [ "''${#fhs_args[@]}" -gt 0 ]; then
          args+=(--tmpfs "$fhs_dir" "''${fhs_args[@]}" --remount-ro "$fhs_dir")
        fi
      done

      ${lib.optionalString hasNetwork ''
        # resolved answers over a unix socket, which would carry lookups around a network setup's tunnel.
        if [ -z "''${CONFINE_NETWORK_SETUP_BIN:-}" ]; then
          args+=(--ro-bind-try /run/systemd/resolve /run/systemd/resolve)
        fi
      ''}

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

      ${lib.optionalString (!cfg.hostAccounts) ''
        # Only this user and the overflow id, as Flatpak writes them, so the host's other accounts stay out.
        user_name=$(id -un)
        group_name=$(id -gn)
        real_name=$(getent passwd "$(id -u)" | cut -d: -f5) || real_name=""
        printf '%s:x:%s:%s:%s:%s:/bin/sh\nnfsnobody:x:65534:65534:Unmapped user:/:/sbin/nologin\n' \
          "$user_name" "$(id -u)" "$(id -g)" "$real_name" "$HOME" > "$instance/passwd"
        printf '%s:x:%s:%s\nnfsnobody:x:65534:\n' "$group_name" "$(id -g)" "$user_name" > "$instance/group"
        args+=(--ro-bind "$instance/passwd" /etc/passwd --ro-bind "$instance/group" /etc/group)
      ''}

      # Host plugin trees (QT_PLUGIN_PATH, GTK_PATH, QML2_IMPORT_PATH, GIO_EXTRA_MODULES) stay out because mismatched toolkit plugins crash apps and GSettings must fall back to the keyfile backend.
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
        # shellcheck disable=SC2043 # a single declared name is still a list
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
      # Always quoted, escapeShellArgs leaves commas bare and shellcheck fails the build on them inside an array (SC2054).
      args+=(${
        lib.concatMapStringsSep " " (s: "'${lib.replaceStrings [ "'" ] [ "'\\''" ] s}'") (
          lib.concatMap (n: [
            "--setenv"
            n
            cfg.env.${n}
          ]) (lib.attrNames cfg.env)
        )
      })

      mkdir -p "$runtime_dir/app/${appId}"
      chmod 700 "$runtime_dir/app/${appId}"
      args+=(--bind "$runtime_dir/app/${appId}" "$runtime_dir/app/${appId}")

      # Folders the sandbox shares with the host as themselves, for the guards and for file forwarding, which only some apps turn on.
      # shellcheck disable=SC2034
      {
        rw_roots=()
        visible_roots=(/nix/store "$runtime_dir/doc")
        declare -A pinned=()
      }

      ${lib.optionalString needsGuard ''
        pin_dir() {
          if [ -z "''${pinned[$1]:-}" ]; then
            pinned[$1]=1
            args+=(--bind "$1" "$1")
          fi
        }

        # A read only path inside a writable shared folder could be swapped out from inside by renaming a folder above it, so every folder in between is pinned in place and none of them may be a link.
        guard_path() {
          local path=$1 root best="" rel dir part
          for root in ''${rw_roots[@]+"''${rw_roots[@]}"}; do
            if [[ "$path" == "$root"/* ]] && [ "''${#root}" -gt "''${#best}" ]; then
              best=$root
            fi
          done
          [ -n "$best" ] || return 0
          rel=''${path#"$best"/}
          dir=$best
          local IFS=/ parts=()
          read -ra parts <<< "$rel"
          for part in "''${parts[@]}"; do
            [ -n "$part" ] || continue
            dir="$dir/$part"
            if [ -L "$dir" ]; then
              echo "confine: refusing to start, $dir is a link inside a shared folder, so the sandbox could redirect what it guards" >&2
              exit 1
            fi
            if [ "$dir" != "$path" ] && [ -d "$dir" ]; then
              pin_dir "$dir"
            fi
          done
        }
      ''}

      ${
        if homeMode == "private" then
          ''
            private_home=''${XDG_DATA_HOME:-$HOME/.local/share}/confine/${appId}
            mkdir -p "$private_home"
            args+=(--bind "$private_home" "$HOME")
          ''
        else if homeMode == "ephemeral" then
          ''
            args+=(--dir "$HOME")
          ''
        else
          ''
            args+=(--bind "$HOME" "$HOME")
            rw_roots+=("$HOME")
            visible_roots+=("$HOME")
          ''
      }

      ${lib.optionalString (cfg.workdir != null || cfg.binds.ro != [ ] || cfg.binds.rw != [ ]) ''
        launch_dir=$(pwd -P)
      ''}
      ${lib.optionalString (cfg.workdir != null) ''
        # The home itself, or anything above it, would hand over every file the sandbox exists to hide. HOME can point elsewhere, the account's home cannot.
        account_home=$(getent passwd "$(id -u)" | cut -d: -f6)
        for home_dir in "$HOME" "$account_home"; do
          if [ "$launch_dir" = / ] || { [ -n "$home_dir" ] && [[ "$home_dir/" == "$launch_dir"/* ]]; }; then
            echo "confine: refusing to share $launch_dir, it contains your whole home" >&2
            exit 1
          fi
        done
        args+=(${if cfg.workdir == "rw" then "--bind" else "--ro-bind"} "$launch_dir" "$launch_dir" --chdir "$launch_dir")
        ${lib.optionalString (cfg.workdir == "rw") ''
          rw_roots+=("$launch_dir")
        ''}
        visible_roots+=("$launch_dir")
      ''}

      ${lib.optionalString (cfg.binds.ro != [ ] || cfg.binds.rw != [ ]) ''
        ${lib.optionalString usesXdgNames ''
          # Flatpak's names for the user folders. user-dirs.dirs is parsed, not sourced, since it is user data.
          xdg_path() {
            local spec=$1 name rest key value dirs_file
            name=''${spec%%/*}
            rest=''${spec#"$name"}
            case "$name" in
              xdg-config) printf '%s%s' "''${XDG_CONFIG_HOME:-$HOME/.config}" "$rest"; return 0 ;;
              xdg-cache) printf '%s%s' "''${XDG_CACHE_HOME:-$HOME/.cache}" "$rest"; return 0 ;;
              xdg-data) printf '%s%s' "''${XDG_DATA_HOME:-$HOME/.local/share}" "$rest"; return 0 ;;
              xdg-state) printf '%s%s' "''${XDG_STATE_HOME:-$HOME/.local/state}" "$rest"; return 0 ;;
              xdg-desktop) key=DESKTOP value=Desktop ;;
              xdg-documents) key=DOCUMENTS value=Documents ;;
              xdg-download) key=DOWNLOAD value=Downloads ;;
              xdg-music) key=MUSIC value=Music ;;
              xdg-pictures) key=PICTURES value=Pictures ;;
              xdg-public-share) key=PUBLICSHARE value=Public ;;
              xdg-videos) key=VIDEOS value=Videos ;;
              xdg-templates) key=TEMPLATES value=Templates ;;
              *) return 1 ;;
            esac
            value="$HOME/$value"
            dirs_file=''${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs
            if [ -r "$dirs_file" ]; then
              local line
              while IFS= read -r line; do
                case "$line" in
                  "XDG_''${key}_DIR=\""*\")
                    line=''${line#*=\"}
                    line=''${line%\"}
                    case "$line" in
                      \$HOME/*) value="$HOME/''${line#\$HOME/}" ;;
                      /*) value=$line ;;
                    esac
                    ;;
                esac
              done < "$dirs_file"
            fi
            # A disabled user folder points at the home itself, which Flatpak leaves out too.
            if [ "$value" = "$HOME" ] || [ "$value" = "$HOME/" ]; then
              echo "confine: $name is the whole home, left out" >&2
              return 1
            fi
            printf '%s%s' "$value" "$rest"
          }
        ''}

        add_bind() {
          local mode=$1 from=$2 to=$3 src dest
          case "$from" in
            xdg-run/*) src="$runtime_dir/''${from#xdg-run/}" ;;
            xdg-*) src=$(xdg_path "$from") || return 0 ;;
            ./*) src="$launch_dir/''${from#./}" ;;
            /*) src="$from" ;;
            *)  src="$HOME/$from" ;;
          esac
          case "$to" in
            xdg-run/*) dest="$runtime_dir/''${to#xdg-run/}" ;;
            xdg-*) dest=$(xdg_path "$to") || return 0 ;;
            ./*) dest="$launch_dir/''${to#./}" ;;
            /*) dest="$to" ;;
            *)  dest="$HOME/$to" ;;
          esac

          # Absolute paths are never created, that would paper over an unmounted disk.
          if [ "$mode" = rw ]; then
            case "$from" in
              /* | ./*) : ;;
              *)  mkdir -p "$src" ;;
            esac
            args+=(--bind-try "$src" "$dest")
            if [ "$src" = "$dest" ] && [ -d "$src" ]; then
              rw_roots+=("$src")
            fi
          else
            if [ "$src" = "$dest" ] && { [ -e "$src" ] || [ -L "$src" ]; }; then
              guard_path "$src"
            fi
            args+=(--ro-bind-try "$src" "$dest")
          fi
          if [ "$src" = "$dest" ]; then
            visible_roots+=("$src")
          fi
        }

        ${lib.optionalString (lib.any isPattern (cfg.binds.ro ++ cfg.binds.rw)) ''
          # A pattern binds whatever matches when the app starts, each match at its own path.
          add_matches() {
            local mode=$1 pattern=$2 match matches
            case "$pattern" in
              /*) : ;;
              xdg-*) pattern=$(xdg_path "$pattern") || return 0 ;;
              ./*) pattern="$launch_dir/''${pattern#./}" ;;
              *) pattern="$HOME/$pattern" ;;
            esac
            shopt -s nullglob
            # shellcheck disable=SC2206 # the pattern is a glob on purpose
            matches=($pattern)
            shopt -u nullglob
            for match in ''${matches[@]+"''${matches[@]}"}; do
              add_bind "$mode" "$match" "$match"
            done
          }
        ''}

        # Writable binds come first, a later mount of a parent would hide a read only path inside it.
        ${lib.concatMapStrings (
          mode:
          lib.concatMapStrings (
            b:
            if isPattern b then
              ''
                add_matches ${mode} ${lib.escapeShellArg b}
              ''
            else
              let
                n = normaliseBind b;
              in
              ''
                add_bind ${mode} ${lib.escapeShellArg n.from} ${lib.escapeShellArg n.to}
              ''
          ) cfg.binds.${mode}
        ) [ "rw" "ro" ]}
      ''}

      ${lib.optionalString (cfg.symlinks != [ ]) ''
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

      ${lib.optionalString cfg.gitGuard.enable ''
        find_git() {
          find "$1" -maxdepth ${toString cfg.gitGuard.depth} \( -name node_modules -prune \) -o \( -name .git -print0 -prune \) 2>/dev/null
        }

        # Git outside the sandbox later runs a repository's hooks and config commands, and follows commondir to another repository's config, so each repository in a writable shared folder keeps those read only, with its .git pinned so it cannot be renamed away and rebuilt.
        guard_git_dir() {
          local gitdir=$1 sub
          pin_dir "$gitdir"
          for sub in config config.worktree commondir; do
            if [ -e "$gitdir/$sub" ] || [ -L "$gitdir/$sub" ]; then
              guard_path "$gitdir/$sub"
              args+=(--ro-bind "$gitdir/$sub" "$gitdir/$sub")
            fi
          done
          if [ -e "$gitdir/hooks" ] || [ -L "$gitdir/hooks" ]; then
            guard_path "$gitdir/hooks"
            args+=(--ro-bind "$gitdir/hooks" "$gitdir/hooks")
          else
            # The sandbox could otherwise create the folder, so an empty read only one takes its place.
            args+=(--ro-bind "$instance/empty" "$gitdir/hooks")
          fi
        }

        mkdir -m 755 "$instance/empty"
        : > "$instance/git-guarded"
        for root in ''${rw_roots[@]+"''${rw_roots[@]}"}; do
          while IFS= read -r -d "" git_path; do
            guard_path "$git_path"
            printf '%s\n' "$git_path" >> "$instance/git-guarded"
            if [ -f "$git_path" ]; then
              args+=(--ro-bind "$git_path" "$git_path")
              continue
            fi
            if [ -e "$git_path/commondir" ]; then
              printf '%s\n' "$git_path/commondir" >> "$instance/git-guarded"
            fi
            guard_git_dir "$git_path"
            for nested in "$git_path"/modules/* "$git_path"/worktrees/*; do
              if [ -d "$nested" ] && [ ! -L "$nested" ]; then
                guard_git_dir "$nested"
              fi
            done
          done < <(find_git "$root")
        done

        git_is_risky() {
          local gitdir=$1 hook
          # A gitfile made inside points git at a folder of the sandbox's choosing.
          [ -f "$gitdir" ] && return 0
          for hook in "$gitdir"/hooks/*; do
            if [ -f "$hook" ] && [ -x "$hook" ] && [[ "$hook" != *.sample ]]; then
              return 0
            fi
          done
          grep -qiE '^[[:space:]]*(fsmonitor|hookspath|sshcommand|askpass|pager|editor|textconv|clean|smudge|process|program|helper|driver|external|command)[[:space:]]*=|^[[:space:]]*\[(include|includeif)' \
            "$gitdir/config" "$gitdir/config.worktree" 2>/dev/null
        }

        # Repositories made while the sandbox ran had no guard, and a commondir in a checkout redirects git to another repository's config, so those are reported when the sandbox ends and the commondir is removed.
        audit_git() {
          local root git_path flagged=() summary
          [ -f "$instance/git-guarded" ] || return 0
          for root in ''${rw_roots[@]+"''${rw_roots[@]}"}; do
            while IFS= read -r -d "" git_path; do
              if [ -d "$git_path" ] && [ -e "$git_path/commondir" ] \
                && ! grep -qxF "$git_path/commondir" "$instance/git-guarded"; then
                rm -f "$git_path/commondir"
                flagged+=("$git_path/commondir (removed)")
              fi
              if ! grep -qxF "$git_path" "$instance/git-guarded" && git_is_risky "$git_path"; then
                flagged+=("$git_path")
              fi
            done < <(find_git "$root")
          done
          [ "''${#flagged[@]}" -gt 0 ] || return 0
          summary="Repositories changed inside ${name} could run code through git outside it: ''${flagged[*]}"
          echo "confine: $summary" >&2
          busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications \
            org.freedesktop.Notifications Notify 'susssasa{sv}i' confine 0 dialog-warning \
            "Check these repositories before using git on them" "$summary" 0 0 -1 >/dev/null 2>&1 || true
        }
      ''}

      ${lib.optionalString (cfg.devices != [ ]) ''
        ${lib.optionalString (!cfg.securityKeys) ''
          # udev tags FIDO and other security keys, and an app that did not ask for one should not be able to request signatures from it.
          is_security_key() {
            local major minor line
            [ -c "$1" ] || return 1
            read -r major minor < <(stat -c '%t %T' "$1") || return 1
            while IFS= read -r line; do
              if [ "$line" = E:ID_SECURITY_TOKEN=1 ]; then
                return 0
              fi
            done 2>/dev/null < "/run/udev/data/c$((16#$major)):$((16#$minor))"
            return 1
          }
        ''}

        add_devices() {
          local pattern=$1 dev matches
          shopt -s nullglob
          # shellcheck disable=SC2206 # the pattern is a glob on purpose
          matches=($pattern)
          shopt -u nullglob
          for dev in ''${matches[@]+"''${matches[@]}"}; do
            if [ -e "$dev" ]; then
              # A link such as /dev/input/by-id/*-fido is bound at its target, the path programs find through sysfs.
              dev=$(readlink -f "$dev")
              ${lib.optionalString (!cfg.securityKeys) ''
                if is_security_key "$dev"; then
                  echo "confine: left out $dev, a security key, which needs securityKeys = true" >&2
                  continue
                fi
              ''}
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
        context_socket=$host_wayland_socket
      ''}

      ${lib.optionalString useSecurityContext ''
        # The compositor keeps fake input, screen capture, window management and background clipboard reads from security context clients, the way it does for Flatpak.
        if [ -z "''${CONFINE_WAYLAND_SANDBOXED:-}" ]; then
          context_socket=confine-${appId}.$instance_id.context
          mkfifo -m 600 "$instance/security-context"
          ${securityContext}/bin/confine-security-context "$runtime_dir/$context_socket" confine \
            ${lib.escapeShellArg contextAppId} "$instance_id" > "$instance/security-context" &
          security_context_pid=$!
          if ! read -r -t 10 context_state < "$instance/security-context" || [ "$context_state" != ready ]; then
            echo "confine: the compositor did not accept a Wayland security context, refusing to start without one" >&2
            exit 1
          fi
        fi
        # A nested launch reuses its socket, which already belongs to a context, since compositors hide the context manager from it.
        args+=(--setenv CONFINE_WAYLAND_SANDBOXED 1)
      ''}

      ${lib.optionalString cfg.wayland ''
        wayland_socket=$context_socket
      ''}

      ${lib.optionalString useWaylandProxy ''
        # Relays only core protocols, which also drops GPU buffer sharing, input methods and fractional scaling, so it stays off by default.
        wayland_socket=confine-${appId}.$instance_id
        WAYLAND_DISPLAY=$context_socket wayland-proxy-virtwl --wayland-display="$wayland_socket" &
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
        args+=(
          --ro-bind "$runtime_dir/$wayland_socket" "$runtime_dir/$host_wayland_socket"
          --setenv WAYLAND_DISPLAY "$host_wayland_socket"
        )
      ''}

      ${lib.optionalString isolatedX11 ''
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
          --ro-bind "$runtime_dir/$context_socket" "$runtime_dir/$host_wayland_socket"
          --bind "$x11_dir" /tmp/.X11-unix
          --setenv XDG_RUNTIME_DIR "$runtime_dir"
          --setenv WAYLAND_DISPLAY "$host_wayland_socket"
          --unsetenv DISPLAY
        )

        ${lib.optionalString cfg.gpu ''
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
        # libpulse chmods $XDG_RUNTIME_DIR/pulse and fails when it is a bind target.
        # enable-shm=no, shm needs a shared /dev/shm and IPC namespace.
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
              # The portal inspects the bus peer, the proxy, so the forged /.flatpak-info must sit in the proxy's own namespace.
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

            # The proxy writes one byte on --fd when ready and exits when that fd closes, so the read end is held for the whole run.
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

      args+=(--info-fd 4)
      export CONFINE_INFO="$instance/info"

      ${lib.optionalString isolatedNetwork ''
        # pasta maps the caller to uid 0 and Chromium refuses to run as root.
        args+=(--uid "$(id -u)" --gid "$(id -g)")

        # Forwards default to "auto", exposing every loopback service, so they start closed.
        # --no-map-gw and the outbound pin close the other routes.
        pasta_args=(
          --config-net --no-map-gw --quiet
          -t '${portSpec cfg.networkPorts.fromHost}' -u '${portSpec cfg.networkPorts.fromHost}'
          -T '${portSpec cfg.networkPorts.toHost}'   -U '${portSpec cfg.networkPorts.toHost}'
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

      ${lib.optionalString cfg.portals ''
        # Files handed over from outside arrive between @@ markers, as in Flatpak's desktop entries, and one the sandbox cannot already see is exported through the document portal for this app alone.
        path_visible() {
          local path=$1 root
          for root in "''${visible_roots[@]}"; do
            if [ "$path" = "$root" ] || [[ "$path" == "$root"/* ]]; then
              return 0
            fi
          done
          return 1
        }

        uri_encode() {
          local LC_ALL=C s=$1 out="" c i hex
          for ((i = 0; i < ''${#s}; i++)); do
            c=''${s:i:1}
            case "$c" in
              [A-Za-z0-9/._~-]) out+=$c ;;
              *)
                printf -v hex '%%%02X' "'$c"
                out+=$hex
                ;;
            esac
          done
          printf '%s' "$out"
        }

        forward_arg() {
          local mode=$1 arg=$2 path doc_id doc_path
          path=$arg
          if [ "$mode" = @@u ]; then
            case "$arg" in
              file://*)
                path=''${arg#file://}
                path=''${path#localhost}
                path=$(printf '%b' "''${path//%/\\x}")
                ;;
              /*) ;;
              *)
                printf '%s' "$arg"
                return 0
                ;;
            esac
          fi
          path=$(realpath -m -- "$path")
          if [ ! -e "$path" ] || path_visible "$path"; then
            printf '%s' "$arg"
            return 0
          fi
          if ! doc_id=$(${helpers}/bin/confine-document-add ${appId} "$path"); then
            echo "confine: could not hand $path to the document portal" >&2
            printf '%s' "$arg"
            return 0
          fi
          doc_path="$runtime_dir/doc/$doc_id/$(basename -- "$path")"
          if [ "$mode" = @@u ]; then
            printf 'file://%s' "$(uri_encode "$doc_path")"
          else
            printf '%s' "$doc_path"
          fi
        }

        forwarded=()
        forwarding=""
        for arg in "$@"; do
          case "$arg" in
            @@ | @@u)
              if [ -z "$forwarding" ]; then
                forwarding=$arg
              else
                forwarding=""
              fi
              continue
              ;;
          esac
          if [ -n "$forwarding" ]; then
            arg=$(forward_arg "$forwarding" "$arg")
          fi
          forwarded+=("$arg")
        done
        set -- ''${forwarded[@]+"''${forwarded[@]}"}
      ''}

      args+=(${lib.escapeShellArgs cfg.extraBwrapArgs})

      # shellcheck disable=SC2016 # the inner script must not expand out here
      launch=(${runtimeShell} -c ${lib.escapeShellArg innerScript} confine
              "''${args[@]}" -- "$target" "$@")

      ${lib.optionalString isolatedNetwork ''
        launch=(pasta "''${pasta_args[@]}" -- "''${launch[@]}")
      ''}

      # bwrap writes its pid and namespaces once the sandbox stands. Reading them on the side records the instance for confine ps and enter, and for the portal, without holding up the app or taking its signals.
      mkfifo -m 600 "$instance/info"
      (
        if timeout 10 cat "$instance/info" > "$instance/bwrapinfo.json" && [ -s "$instance/bwrapinfo.json" ]; then
          want=$(sed -n 's/.*"mnt-namespace": *\([0-9]*\).*/\1/p' "$instance/bwrapinfo.json")
          sandbox_pid=""
          if [ -n "$want" ]; then
            for _ in $(seq 40); do
              if sandbox_pid=$(find_sandbox_pid "$want"); then
                break
              fi
              sandbox_pid=""
              sleep 0.025
            done
          fi
          if [ -n "$sandbox_pid" ]; then
            printf 'pid=%s\n' "$sandbox_pid" >> "$instance/state"
            ${lib.optionalString cfg.portals ''
              # The portal opens a pidfd on child-pid, and since 1.19 a missing file fails the whole lookup.
              sed "s/\"child-pid\": *[0-9]*/\"child-pid\": $sandbox_pid/" "$instance/bwrapinfo.json" \
                > "$flatpak_dir/bwrapinfo.json"
            ''}
          else
            echo "confine: could not find the sandbox's pid${lib.optionalString cfg.portals ", portals may not identify this app"}" >&2
          fi
        fi
      ) &
      info_pid=$!

      "''${launch[@]}"${closeSyncFd}
    '';
  };

  binaryList =
    if cfg.binaries == null then ''$(cd "${package}/bin" && ls)'' else lib.escapeShellArgs cfg.binaries;

  binPrefixLabel =
    let
      m = builtins.match "(.*[A-Za-z0-9])[-_.]*" cfg.binPrefix;
    in
    if m == null then cfg.binPrefix else lib.head m;
in

checked (runCommand confinedName
  {
    inherit version;
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

      # Overriding re-confines so programs.steam cannot return an unconfined build.
      # setFunctionArgs keeps the signature lib.functionArgs callers see.
      override = lib.setFunctionArgs (
        f: confineAgain (package.override f)
      ) (lib.functionArgs (package.override or (x: x)));

      overrideAttrs = f: confineAgain (package.overrideAttrs f);
      dbusArgs = {
        session = sessionProxyArgs;
        system = systemProxyArgs;
      };
    };
  }
  ''
    mkdir -p "$out/bin"

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

    # foot keeps terminfo in a separate output, losing it breaks terminals inside.
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

    if [ -d ${package}/share/applications ]; then
      mkdir -p "$out/share/applications"
      entries=(${package}/share/applications/*.desktop)

      for desktop in "''${entries[@]}"; do
        # Portals resolve the app id to a matching .desktop for name and icon, so a lone entry is renamed to the forged id.
        if [ "''${#entries[@]}" -eq 1 ] && ${lib.boolToString (!cfg.keepDesktopNames)}; then
          dest="$out/share/applications/${appId}.desktop"
        else
          dest="$out/share/applications/$(basename "$desktop")"
        fi

        cp "$desktop" "$dest"
        chmod +w "$dest"
        for bin in "''${binaries[@]}"; do
          sed -i -E "s#^(Exec|TryExec)=([^ ]*/)?$bin([[:space:]]|\$)#\1=$out/bin/${cfg.binPrefix}$bin\3#" "$dest"
        done
        ${lib.optionalString cfg.portals ''
          # File and URL field codes are fenced the way Flatpak exports them, so the launcher can hand those files over.
          sed -i -E \
            -e '/^Exec=/s/(^|[[:space:]])%([fF])([[:space:]]|$)/\1@@ %\2 @@\3/g' \
            -e '/^Exec=/s/(^|[[:space:]])%([uU])([[:space:]]|$)/\1@@u %\2 @@\3/g' \
            "$dest"
        ''}
        ${lib.optionalString (cfg.binPrefix != "") ''
          sed -i "0,/^Name=/s/^Name=\(.*\)/Name=\1 (${binPrefixLabel})/" "$dest"
        ''}
      done

      ${lib.optionalString cfg.keepDesktopNames ''
        # The kept name shadows the unconfined entry, a hidden copy under the app id still serves the portals.
        if [ "''${#entries[@]}" -eq 1 ] && [ "$dest" != "$out/share/applications/${appId}.desktop" ]; then
          sed -e '/^NoDisplay=/d' -e '/^\[Desktop Entry\]$/a NoDisplay=true' "$dest" \
            > "$out/share/applications/${appId}.desktop"
        fi
      ''}
    fi
  '')
)
