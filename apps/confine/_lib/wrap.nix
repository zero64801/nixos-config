{
  lib,
  callPackage,
  runCommand,
  writeText,
  bubblewrap,
  flatpak-xdg-utils,
  passt,
  wayland-proxy-virtwl,
  xdg-dbus-proxy,
  xwayland-satellite,
  shared ? { },
}:

let
  mkFilter = callPackage ./seccomp.nix { };
  launch = callPackage ./launch.nix { };
  profiles = import ./profiles.nix;

  # Stock, a service in the sandbox cannot signal the caller it answers when that caller is in the sandbox too.
  busProxy = xdg-dbus-proxy.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./dbus-proxy-siblings.patch ];
  });

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
    linger = true;
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
      userns = false;
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
  perApp = [ "name" "binaries" "binPrefix" "keepDesktopNames" "waylandAppId" ];

  bindPath = b: if lib.isString b then b else b.from;

  # The scope properties the launcher can type for systemd, with systemd-run's spellings.
  resourcePatterns = {
    MemoryMax = "size";
    MemoryHigh = "size";
    MemorySwapMax = "size";
    MemoryLow = "size";
    MemoryMin = "size";
    CPUWeight = "number";
    StartupCPUWeight = "number";
    IOWeight = "number";
    StartupIOWeight = "number";
    TasksMax = "number";
    CPUQuota = "percent";
  };
  resourceValue = {
    size = "[0-9]+[KMGT]?|infinity";
    number = "[0-9]+|infinity";
    percent = "[0-9]+%";
  };
  validResource =
    k: v: resourcePatterns ? ${k} && builtins.match resourceValue.${resourcePatterns.${k}} (toString v) != null;
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
    (shared.profile or [ ]) ++ (settings.profile or [ ])
  );

  # What the host sets for every app sits under the profiles, so an app's own value still wins.
  cfg = lib.foldl' merge defaults (
    [ (removeAttrs shared [ "profile" ]) ] ++ selected ++ [ (removeAttrs settings [ "profile" ]) ]
  );

  inherit (cfg) appId package;

  checked =
    if unknownShared != [ ] then
      throw "confine: defaults cannot set ${lib.concatStringsSep ", " unknownShared}, a name there is unknown or belongs to one app"
    else if unknownKeys != [ ] then
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
    else if !lib.all (k: validResource k cfg.resources.${k}) (lib.attrNames cfg.resources) then
      throw "confine: resources take ${lib.concatStringsSep ", " (lib.attrNames resourcePatterns)}, with sizes like 4G, numbers or infinity, and CPUQuota as a percentage"
    else if cfg.resources != { } && !cfg.scope then
      throw "confine: resources are set on the app's scope, so they need scope = true"
    else if lib.any (n: builtins.match "[A-Za-z0-9_-]+" n == null) (lib.attrNames cfg.networkSetups) then
      throw "confine: networkSetups names may only contain letters, digits, dash and underscore"
    else if cfg.networkSetups != { } && !isolatedNetwork then
      throw "confine: networkSetups need network = \"isolated\", they run inside pasta's namespace"
    else if namespaceGuard && (cfg.seccomp.multiarch || cfg.seccomp.ioUring) then
      throw "confine: seccomp.userns cannot be combined with seccomp.multiarch or seccomp.ioUring, both make sockets where no filter sees them, so the userns tier could not keep an app from administering a network of its own. seccomp.nesting allows either."
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

  unknownShared = lib.subtractLists (lib.subtractLists perApp (lib.attrNames defaults)) (lib.attrNames shared);

  portSpec =
    ports:
    if ports == [ ] then
      "none"
    else if lib.all (p: lib.isInt p || lib.isString p) ports then
      lib.concatMapStringsSep "," toString ports
    else
      throw "confine: networkPorts entries must be integers or pasta port specs";

  # A port without an address listens on the host's loopback alone, pasta's own default is every address.
  fromHostSpec =
    p:
    if lib.isInt p then
      "127.0.0.1/${toString p}"
    else if lib.isString p then
      (if lib.hasInfix "/" p then p else "127.0.0.1/${p}")
    else
      throw "confine: networkPorts entries must be integers or pasta port specs";

  # An app that may create user namespaces is the admin of any network it makes for itself. The launcher keeps it from using that.
  namespaceGuard = cfg.seccomp.enable && cfg.seccomp.userns && !cfg.seccomp.nesting;

  filter = mkFilter {
    inherit (cfg.seccomp)
      nesting
      userns
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

  useWaylandProxy = cfg.waylandProxy && cfg.wayland;
  useSecurityContext = cfg.waylandSecurityContext && (cfg.wayland || isolatedX11);
  contextAppId = if cfg.waylandAppId != null then cfg.waylandAppId else appId;

  staticArgs =
    [ "--unshare-all" ]
    # In isolated mode this keeps pasta's namespace rather than the host's.
    ++ lib.optional hasNetwork "--share-net"
    # The kernel half of the namespace lock, so a gap in the seccomp half cannot give the app a mount table of its own, the pairing Flatpak uses.
    ++ lib.optionals (!cfg.seccomp.nesting && !cfg.seccomp.userns) [
      "--unshare-user"
      "--disable-userns"
    ]
    ++ [
      "--die-with-parent"
      "--clearenv"
      "--proc"
      "/proc"
    ]
    # bwrap only covers /proc/sys where it could write there itself, and the admin of a network namespace can write that namespace's settings.
    # Kept to this tier: a nested bwrap sets its own namespace limit through the same folder.
    ++ lib.optionals namespaceGuard [
      "--ro-bind"
      "/proc/sys"
      "/proc/sys"
    ]
    ++ [
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

  normaliseForLaunch =
    b:
    if lib.isString b then
      {
        from = b;
        to = b;
        pattern = isPattern b;
      }
    else
      {
        inherit (b) from to;
        pattern = false;
      };

  # Everything the launcher reads at start, so starting an app parses one file and runs no shell.
  launchConfig = writeText "confine-${name}.json" (
    builtins.toJSON {
      inherit appId name contextAppId;
      dataDirsPrefix = "${package}/share";
      tools = {
        bwrap = "${bubblewrap}/bin/bwrap";
        pasta = if isolatedNetwork then "${passt}/bin/pasta" else null;
        dbusProxy = if useProxy then "${busProxy}/bin/xdg-dbus-proxy" else null;
        dbusProxyFilter = if useProxy then "${mkFilter { }}" else null;
        satellite = if isolatedX11 then "${xwayland-satellite}/bin/xwayland-satellite" else null;
        waylandProxy = if useWaylandProxy then "${wayland-proxy-virtwl}/bin/wayland-proxy-virtwl" else null;
      };
      inherit staticArgs sysfsDirs maskedFiles maskedDirs;
      filter = if cfg.seccomp.enable then "${filter}" else null;
      inherit namespaceGuard;
      network = networkMode;
      # Forwards default to "auto", exposing every loopback service, so they start closed. --no-map-gw closes the gateway route.
      # The launcher puts those from the host in front, since only one running instance of an app can hold them.
      # --host-lo-to-ns-lo hands a connection made to the host's loopback to the app's loopback, where a server on localhost listens.
      pastaArgs = [
        "--config-net"
        "--no-map-gw"
        "--host-lo-to-ns-lo"
        "--quiet"
        "-T"
        (portSpec cfg.networkPorts.toHost)
        "-U"
        (portSpec cfg.networkPorts.toHost)
      ]
      ++ cfg.extraPastaArgs;
      fromHost = map fromHostSpec cfg.networkPorts.fromHost;
      networkSetups = lib.mapAttrs (_: s: "${s}") cfg.networkSetups;
      inherit (cfg)
        wayland
        pipewire
        pulse
        gpu
        sysfs
        portals
        hostAccounts
        devices
        securityKeys
        symlinks
        runtimeDir
        workdir
        envPassthrough
        scope
        linger
        extraBwrapArgs
        ;
      waylandProxy = useWaylandProxy;
      securityContext = useSecurityContext;
      inherit (cfg) x11;
      home = homeMode;
      bindsRw = map normaliseForLaunch cfg.binds.rw;
      bindsRo = map normaliseForLaunch cfg.binds.ro;
      gitGuard = {
        inherit (cfg.gitGuard) enable depth;
      };
      dbus = {
        filter = useProxy;
        sessionArgs = sessionProxyArgs;
        systemArgs = if useProxy && useSystemBus then systemProxyArgs else null;
        a11yArgs = if useA11y then a11yProxyArgs else null;
      };
      env = map (n: [
        n
        cfg.env.${n}
      ]) (lib.attrNames cfg.env);
      # Host plugin trees (QT_PLUGIN_PATH, GTK_PATH, QML2_IMPORT_PATH, GIO_EXTRA_MODULES) stay out because mismatched toolkit plugins crash apps and GSettings must fall back to the keyfile backend.
      hostEnv = [
        "TERM"
        "LANG"
        "LOCALE_ARCHIVE"
        "TZDIR"
        "TERMINFO_DIRS"
        "XDG_SESSION_TYPE"
        "XDG_CURRENT_DESKTOP"
        "XDG_SESSION_DESKTOP"
        "DESKTOP_SESSION"
        "XDG_CONFIG_DIRS"
        "XDG_MENU_PREFIX"
        "XCURSOR_THEME"
        "XCURSOR_SIZE"
        "XCURSOR_PATH"
        "GTK_THEME"
        "QT_QPA_PLATFORMTHEME"
        "QT_STYLE_OVERRIDE"
        "QT_WAYLAND_RECONNECT"
        "KDE_FULL_SESSION"
        "KDE_SESSION_VERSION"
        "GDK_PIXBUF_MODULE_FILE"
        "_JAVA_AWT_WM_NONREPARENTING"
        "XKB_DEFAULT_LAYOUT"
        "XKB_DEFAULT_VARIANT"
        "XKB_DEFAULT_MODEL"
        "XKB_DEFAULT_OPTIONS"
        "XKB_DEFAULT_RULES"
        "SSL_CERT_FILE"
        "NIX_SSL_CERT_FILE"
        "NIXOS_OZONE_WL"
        "ELECTRON_OZONE_PLATFORM_HINT"
      ];
      gpuEnv = [
        "__EGL_VENDOR_LIBRARY_FILENAMES"
        "VK_LOADER_DRIVERS_DISABLE"
        "VK_DRIVER_FILES"
        "VK_ICD_FILENAMES"
        "LIBVA_DRIVER_NAME"
        "DRI_PRIME"
        "__NV_PRIME_RENDER_OFFLOAD"
        "__GLX_VENDOR_LIBRARY_NAME"
        "__VK_LAYER_NV_optimus"
      ];
      resources = map (k: [
        k
        (toString cfg.resources.${k})
      ]) (lib.attrNames cfg.resources);
    }
  );

  # The kernel runs the launcher binary as this script's interpreter, so a start costs no shell at all.
  launcher = runCommand "confine-${name}" { } ''
    mkdir -p "$out/bin"
    printf '#!%s\nconfig %s\n' ${launch}/bin/confine-launch ${launchConfig} > "$out/bin/confine-${name}"
    chmod +x "$out/bin/confine-${name}"
  '';

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
      inherit filter launcher launchConfig;
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
      printf '#!%s\nconfig %s\ntarget %s\n' \
        ${launch}/bin/confine-launch ${launchConfig} "${package}/bin/$bin" \
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
