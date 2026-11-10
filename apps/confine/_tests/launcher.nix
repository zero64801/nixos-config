# nix build --impure --no-link --expr 'import ./apps/confine/_tests/launcher.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

let
  inherit (pkgs) lib;
  wrap = pkgs.callPackage ../_lib/wrap.nix { };
  launch = pkgs.callPackage ../_lib/launch.nix { };

  base = {
    package = pkgs.coreutils;
    binaries = [ "env" ];
    appId = "com.test.Launcher";
  };

  launcherOf =
    settings:
    let
      w = wrap (base // settings);
    in
    "${w.launcher}/bin/${w.launcher.name}";

  configOf = settings: (wrap (base // settings)).launchConfig;

  serviceApp = pkgs.runCommand "svcapp" { } ''
    mkdir -p $out/bin $out/share/dbus-1/services $out/share/systemd/user $out/etc/xdg/autostart
    printf '#!/bin/sh\ntrue\n' > $out/bin/svcapp
    chmod +x $out/bin/svcapp
    printf '[D-BUS Service]\nName=com.test.Svc\nExec=%s/bin/svcapp\n' "$out" \
      > $out/share/dbus-1/services/com.test.Svc.service
    printf '[Service]\nExecStart=%s/bin/svcapp --daemon\n' "$out" \
      > $out/share/systemd/user/svcapp.service
    printf '[Desktop Entry]\nType=Application\nExec=%s/bin/svcapp\n' "$out" \
      > $out/etc/xdg/autostart/svcapp.desktop
    mkdir -p $out/share/applications
    printf '[Desktop Entry]\nType=Application\nName=Svc\nExec=svcapp %%U\n\n[Desktop Action new]\nName=New\nExec=svcapp --new\n' \
      > $out/share/applications/svcapp.desktop
  '';

  wrappedService = wrap {
    package = serviceApp;
    binaries = [ "svcapp" ];
    appId = "com.test.Svc";
  };

  prefixedService = wrap {
    package = serviceApp;
    binaries = [ "svcapp" ];
    appId = "com.test.Prefixed";
    binPrefix = "sb-";
  };

  keptService = wrap {
    package = serviceApp;
    binaries = [ "svcapp" ];
    appId = "com.test.Kept";
    keepDesktopNames = true;
  };

  # xdg-dbus-proxy validates rule names before connecting, so bad rules fail here.
  profileRules = lib.mapAttrsToList (
    profileName: _:
    let
      w = wrap (base // { profile = [ profileName ]; });
    in
    {
      inherit profileName;
      inherit (w.dbusArgs) session system;
    }
  ) (import ../_lib/profiles.nix);

  offline = wrap (base // {
    binaries = [
      "env"
      "ls"
    ];
    portals = false;
    dbus.filter = false;
    env.CONFINE_DECLARED = "declared-wins";
    # Commas stay bare under escapeShellArgs and once failed the build on shellcheck SC2054.
    env.CONFINE_LIST = "a,b,c";
    envPassthrough = [
      "CONFINE_HOSTVAR"
      "CONFINE_DECLARED"
    ];
    binds.ro = [ "xdg-run/confine-shared" ];
    symlinks = [
      {
        link = "xdg-run/ipc-link";
        target = "confine-shared/sock";
      }
    ];
  });

  guarded = wrap (base // {
    binaries = [ "touch" ];
    portals = false;
    dbus.filter = false;
    binds.rw = [ "data" ];
    binds.ro = [
      "data/*/.git/hooks"
      "nothing/*/matches"
    ];
  });

  noDesktop = wrap {
    package = pkgs.hello;
    appId = "com.test.NoDesktop";
  };

  portalService = wrap {
    package = serviceApp;
    binaries = [ "svcapp" ];
    appId = "com.test.Portal";
    portals = true;
  };

  # bash as the app, with coreutils by absolute path, since the build sandbox's /bin/sh is a mount and not a link to mirror.
  shell =
    settings:
    wrap (
      {
        package = pkgs.bash;
        binaries = [ "bash" ];
        appId = "com.test.Shell";
        portals = false;
        dbus.filter = false;
      }
      // settings
    );

  guardProbe = pkgs.runCommandCC "confine-guard-probe" { } ''
    mkdir -p "$out/bin"
    $CC -O1 -Wall -Wextra -Werror -o "$out/bin/guard-probe" ${./guard-probe.c}
  '';

  multiDesktop = wrap {
    package = pkgs.foot;
    appId = "com.test.MultiDesktop";
  };
in
pkgs.runCommand "confine-launcher-behaviour"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.jq
      pkgs.python3
      pkgs.xdg-dbus-proxy
    ];

    launchBin = "${launch}/bin/confine-launch";
    plainLauncher = launcherOf { };
    audioLauncher = launcherOf {
      profile = [
        "gui"
        "audio"
      ];
    };
    isolatedLauncher = launcherOf {
      portals = true;
      network = "isolated";
      networkPorts.toHost = [
        3000
        2081
      ];
      networkPorts.fromHost = [
        "0.0.0.0/8000"
        9000
        "9001-9002"
      ];
    };
    tunnelLauncher = launcherOf {
      network = "isolated";
      networkSetups.probe = pkgs.writeShellScript "probe-setup" "true";
    };
    isolatedX11Launcher = launcherOf {
      profile = [
        "gui"
        "gpu"
      ];
      x11 = "isolated";
    };
    noContextLauncher = launcherOf {
      profile = [ "gui" ];
      waylandSecurityContext = false;
    };
    nestingLauncher = launcherOf { seccomp.nesting = true; };
    usernsLauncher = launcherOf { seccomp.userns = true; };
    sharedLauncher = launcherOf {
      appId = "com.test.Shared";
      runtimeDir = "shared";
    };
    plainConfig = configOf { };
    unscopedConfig = configOf { scope = false; };
    zenConfig = configOf {
      profile = [ "gui" ];
      waylandAppId = "zen-beta";
    };
    devicesConfig = configOf { devices = [ "/dev/hidraw*" ]; };
    keysConfig = configOf {
      devices = [ "/dev/hidraw*" ];
      securityKeys = true;
    };
    limitsConfig = configOf {
      resources = {
        MemoryMax = "4G";
        CPUQuota = "50%";
      };
    };
    inherit (wrappedService) outPath;
    unwrappedService = serviceApp;
    prefixedApp = prefixedService;
    keptApp = keptService;
    offlineApp = offline;
    guardedApp = guarded;
    noDesktopApp = noDesktop;
    multiDesktopApp = multiDesktop;
    portalApp = portalService;
    accountsApp = shell { };
    hostAccountsApp = shell {
      appId = "com.test.HostAccounts";
      hostAccounts = true;
    };
    usernsLockedApp = shell {
      appId = "com.test.UsernsLocked";
      seccomp.enable = false;
    };
    usernsOpenApp = shell {
      appId = "com.test.UsernsOpen";
      seccomp = {
        enable = false;
        nesting = true;
      };
    };
    guardedNamespacesApp = shell {
      appId = "com.test.GuardedNamespaces";
      seccomp.userns = true;
    };
    inherit guardProbe;
    gitApp = shell {
      appId = "com.test.Git";
      binds.rw = [ "data" ];
      gitGuard.enable = true;
    };
    xdgApp = shell {
      appId = "com.test.Xdg";
      binds.ro = [ "xdg-documents" ];
    };
    contextApp = shell {
      appId = "com.test.Context";
      wayland = true;
    };
    forwardApp = shell {
      appId = "com.test.Forward";
      portals = true;
      binds.ro = [ "visible" ];
    };
    limitedApp = shell {
      appId = "com.test.Limited";
      resources.MemoryMax = "1G";
    };
    brokenApp = shell {
      appId = "com.test.Broken";
      extraBwrapArgs = [
        "--ro-bind"
        "/nonexistent-confine-path"
        "/mnt"
      ];
    };
    tidyApp = shell {
      appId = "com.test.Tidy";
      linger = false;
    };
    onlineApp = shell {
      appId = "com.test.Online";
      portals = true;
      network = "host";
    };
  }
  ''
    fail() { echo "confine: $1" >&2; exit 1; }

    export HOME="$TMPDIR/home" XDG_RUNTIME_DIR="$TMPDIR/rt"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR/confine-shared"
    rt=$XDG_RUNTIME_DIR

    # The launcher prints what it would run as JSON.
    plan() {
      CONFINE_DRY_RUN=1 "$@" env 2> plan-err || fail "the dry run of $1 failed: $(cat plan-err)"
    }
    # has FILE KEY ARGS...: the array KEY holds ARGS in a row.
    has() {
      local file=$1 key=$2
      shift 2
      jq -e --arg key "$key" --argjson want "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
        '.[$key] as $a | ($want | length) as $n | any(range(0; ($a | length) - $n + 1); $a[.:. + $n] == $want)' \
        "$file" > /dev/null
    }
    unix_socket() {
      mkdir -p "$(dirname "$1")"
      python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
    }

    plan "$plainLauncher" > plain.json
    has plain.json bwrap --disable-userns || fail "sandboxes without nesting lost the kernel namespace lock"
    plan "$nestingLauncher" > nesting.json
    has nesting.json bwrap --disable-userns && fail "nesting = true still disables user namespaces"
    plan "$usernsLauncher" > userns.json
    has userns.json bwrap --disable-userns && fail "seccomp.userns = true still disables user namespaces"
    has plain.json bwrap --dir "$rt" --chmod 0700 "$rt" || fail "the default runtime dir is no longer private"
    # A server's socket is only shareable if the directory it writes to is host-backed, bind(2) refuses to create one at an existing name.
    plan "$sharedLauncher" > shared.json
    has shared.json bwrap --bind "$rt/app/com.test.Shared" "$rt" \
      || fail "runtimeDir = shared does not back the runtime dir with the app directory"

    # The build sandbox's /bin/sh is a bind mount, so a private /bin with a link stands in for the host's.
    ${pkgs.util-linux}/bin/unshare -Urm ${pkgs.bash}/bin/bash -c "
      ${pkgs.util-linux}/bin/mount -t tmpfs none /bin && ln -s ${pkgs.bash}/bin/bash /bin/sh \
        && CONFINE_DRY_RUN=1 '$plainLauncher' env
    " > fhs.json || fail "the dry run under a private /bin failed"
    has fhs.json bwrap --tmpfs /bin --symlink ${pkgs.bash}/bin/bash /bin/sh --remount-ro /bin \
      || fail "sandboxes no longer get the host's /bin links read only"

    # Instance ids are random like Flatpak's, pids would sit a few apart.
    ids=$(for _ in 1 2 3; do
      plan "$plainLauncher" | jq -r '.bwrap[] | capture("/confine/com\\.test\\.Launcher\\.(?<id>[0-9]+)/passwd$").id'
    done | sort -n)
    [ "$(wc -l <<< "$ids")" = 3 ] || fail "could not read the instance ids: $ids"
    [ $(( $(tail -1 <<< "$ids") - $(head -1 <<< "$ids") )) -gt 100000 ] || fail "instance ids are no longer random: $ids"

    # Without a security context KWin offers sandboxed clients fake input, screen capture and background clipboard reads.
    unix_socket "$rt/pulse/native"
    plan "$audioLauncher" > audio.json
    rm "$rt/pulse/native"
    jq -e --arg rt "$rt" '.bwrap as $a | any(range(0; ($a | length) - 2);
        $a[.] == "--ro-bind" and ($a[. + 1] | test("/confine-com\\.test\\.Launcher\\.[0-9]+\\.context$")) and $a[. + 2] == $rt + "/wayland-0")' \
      audio.json > /dev/null || fail "a Wayland app starts without a security context"
    has audio.json bwrap --setenv CONFINE_WAYLAND_SANDBOXED 1 \
      || fail "nested launches cannot tell they already sit in a security context"
    plan "$noContextLauncher" > nocontext.json
    grep -q '\.context"' nocontext.json && fail "waylandSecurityContext = false still creates a context"
    grep -q '\.context"' plain.json && fail "an app without Wayland creates a security context"
    [ "$(jq -r .contextAppId "$zenConfig")" = zen-beta ] || fail "waylandAppId does not reach the compositor"

    has audio.json bwrap --ro-bind "$rt/pulse/native" /run/flatpak/pulse/native || fail "the pulse socket is not bound"
    # pasta closes inherited descriptors, so nothing may reach bwrap on one but the filter and info it opens itself.
    jq -e '[.bwrap[] | select(. == "--ro-bind-data" or . == "--bind-data" or . == "--file" or . == "--args"
        or . == "--seccomp" or . == "--info-fd" or . == "--userns" or . == "--block-fd" or . == "--sync-fd")] == []' \
      audio.json > /dev/null || fail "the planned command line hands bwrap a descriptor"

    plan "$tunnelLauncher" > tunnel.json
    # resolved's socket would carry lookups around the tunnel.
    has tunnel.json bwrap --ro-bind-try /run/systemd/resolve /run/systemd/resolve \
      || fail "the resolved socket is not bound for launches without a network setup"
    CONFINE_NETWORK_SETUP=probe plan "$tunnelLauncher" > tunnel-setup.json
    grep -q /run/systemd/resolve tunnel-setup.json && fail "the resolved socket is bound around the network setup"

    plan "$isolatedLauncher" > isolated.json
    has isolated.json pasta -t 0.0.0.0/8000 -u 0.0.0.0/8000 || fail "a networkPorts entry with an address is not passed to pasta as given"
    # pasta's own default for a port without an address is every address, which would put it on the network.
    has isolated.json pasta -t 127.0.0.1/9000 -u 127.0.0.1/9000 || fail "a bare port from the host does not listen on loopback alone"
    has isolated.json pasta -t 127.0.0.1/9001-9002 -u 127.0.0.1/9001-9002 || fail "a port range from the host does not listen on loopback alone"
    has tunnel.json pasta -t none -u none || fail "an app without ports from the host does not close them"
    has isolated.json pasta -T 3000,2081 -U 3000,2081 || fail "ports to the host are not passed to pasta"
    has isolated.json bwrap --share-net || fail "the isolated sandbox does not stay in pasta's namespace"

    plan "$isolatedX11Launcher" > x11.json
    has x11.json satellite --dev-bind-try /dev/dri /dev/dri || fail "the isolated X server is not given the GPU, so GLX will fail"
    has x11.json satellite --ro-bind-try /run/opengl-driver /run/opengl-driver || fail "the isolated X server is not given the driver tree"
    has x11.json satellite --disable-userns || fail "the isolated X server can create user namespaces"

    [ "$(jq .scope "$plainConfig")" = true ] || fail "apps no longer get a scope of their own"
    [ "$(jq .scope "$unscopedConfig")" = false ] || fail "scope = false still creates a scope"
    [ "$(jq -c .resources "$limitsConfig")" = '[["CPUQuota","50%"],["MemoryMax","4G"]]' ] \
      || fail "resources do not reach the launcher: $(jq -c .resources "$limitsConfig")"
    [ "$(jq .securityKeys "$devicesConfig")" = false ] || fail "device wildcards no longer leave security keys out"
    [ "$(jq .securityKeys "$keysConfig")" = true ] || fail "securityKeys = true still filters security keys"

    # pasta's far side runs the network setup before it opens the filter and info descriptors, so nothing the setup
    # leaves running holds them.
    mkfifo inner-args inner-info inner-status
    printf '#!%s\n%s/ls -l /proc/self/fd/ > %s/setup-fds\n' ${pkgs.bash}/bin/bash ${pkgs.coreutils}/bin "$PWD" > setup
    printf '#!%s\nprintf "%%s\\n" "$@" > %s/bwrap-args\n%s/readlink /proc/self/fd/$2 /proc/self/fd/$4 /proc/self/fd/12 > %s/bwrap-fds\n' \
      ${pkgs.bash}/bin/bash "$PWD" ${pkgs.coreutils}/bin "$PWD" > fake-bwrap
    chmod +x setup fake-bwrap
    printf 'filter' > filter.bpf
    cat inner-info > /dev/null &
    cat inner-status > /dev/null &
    "$launchBin" --inner "$PWD/setup" "$PWD/filter.bpf" "$PWD/inner-info" "$PWD/inner-status" "$PWD/fake-bwrap" "$PWD/inner-args" "" "" &
    inner=$!
    printf -- '--ro-bind\0/a\0/b\0' > inner-args
    wait "$inner" || fail "the inner step failed"
    grep -q 'filter.bpf\|inner-info\|inner-status' setup-fds && fail "the network setup ran with a sandbox descriptor open: $(cat setup-fds)"
    [ "$(sed -n '1p;3p;5,7p' bwrap-args | tr '\n' ' ')" = "--seccomp --info-fd --ro-bind /a /b " ] \
      || fail "the inner step passed bwrap the wrong arguments: $(tr '\n' ' ' < bwrap-args)"
    [ "$(tr '\n' ' ' < bwrap-fds)" = "$PWD/filter.bpf $PWD/inner-info $PWD/inner-status " ] \
      || fail "the inner step's descriptors point elsewhere: $(cat bwrap-fds)"
    rm bwrap-args
    printf '#!%s\nexit 1\n' ${pkgs.bash}/bin/bash > setup
    "$launchBin" --inner "$PWD/setup" "$PWD/filter.bpf" "$PWD/inner-info" "$PWD/inner-status" "$PWD/fake-bwrap" "$PWD/inner-args" "" "" &
    inner=$!
    printf -- '--ro-bind\0/a\0/b\0' > inner-args
    wait "$inner" && fail "a failed network setup did not stop the sandbox"
    [ -e bwrap-args ] && fail "bwrap ran after the network setup failed"

    for f in share/dbus-1/services/com.test.Svc.service \
             share/systemd/user/svcapp.service \
             etc/xdg/autostart/svcapp.desktop; do
      grep -q "$unwrappedService/bin" "$outPath/$f" \
        && fail "$f still launches the unwrapped binary"
      grep -q "$outPath/bin" "$outPath/$f" \
        || fail "$f does not point at the wrapper"
    done

    check_rules() {
      local label=$1 out
      shift
      out=$(timeout 2 xdg-dbus-proxy "unix:path=/nonexistent-confine-bus" \
              "$TMPDIR/probe-$label.sock" "$@" 2>&1 || true)
      case "$out" in
        *"not a valid"*) fail "profile $label emits a rule the bus proxy rejects: $out" ;;
      esac
    }
    ${lib.concatMapStrings (p: ''
      check_rules ${p.profileName} ${lib.escapeShellArgs p.session}
      check_rules ${p.profileName}-system ${lib.escapeShellArgs p.system}
    '') profileRules}

    [ -x "$noDesktopApp/bin/hello" ] || fail "a package without a desktop entry lost its binary"
    [ -e "$noDesktopApp/share/applications" ] \
      && fail "an applications directory was invented for a package that has none"

    n=$(find "$multiDesktopApp/share/applications" -name '*.desktop' | wc -l)
    [ "$n" -ge 2 ] || fail "expected several desktop entries, found $n"
    [ -e "$multiDesktopApp/share/applications/com.test.MultiDesktop.desktop" ] \
      && fail "several entries were collapsed onto the application id"
    grep -rq "${pkgs.foot}/bin" "$multiDesktopApp/share/applications" \
      && fail "a desktop entry still points at the unwrapped package"

    lone="$outPath/share/applications/com.test.Svc.desktop"
    [ -e "$lone" ] || fail "the single desktop entry was not renamed to the application id"

    grep -qx "Exec=$outPath/bin/svcapp %U" "$lone" \
      || fail "the main Exec was not rewritten, or the field code was eaten"
    grep -qx "Exec=$outPath/bin/svcapp --new" "$lone" \
      || fail "the Exec under [Desktop Action] was left pointing elsewhere"

    kept="$keptApp/share/applications/svcapp.desktop"
    hidden="$keptApp/share/applications/com.test.Kept.desktop"
    [ -e "$kept" ] || fail "keepDesktopNames renamed the entry"
    grep -qx "Exec=$keptApp/bin/svcapp %U" "$kept" \
      || fail "the kept entry does not launch the shim"
    grep -q '^NoDisplay=' "$kept" && fail "the kept entry was hidden"
    [ -e "$hidden" ] || fail "keepDesktopNames left the portals no entry under the app id"
    [ "$(sed -n '2p' "$hidden")" = "NoDisplay=true" ] \
      || fail "the app id copy is not hidden inside [Desktop Entry]"
    [ "$(grep -c '^NoDisplay=' "$hidden")" -eq 1 ] \
      || fail "NoDisplay landed in a [Desktop Action] group too"
    grep -qx "Exec=$keptApp/bin/svcapp --new" "$hidden" \
      || fail "the hidden copy kept an unconfined action"

    [ -x "$prefixedApp/bin/sb-svcapp" ] || fail "the prefixed shim is missing"
    [ -e "$prefixedApp/bin/svcapp" ] \
      && fail "the unprefixed name is still exposed and collides with the bare package"
    grep -q "$prefixedApp/bin/sb-svcapp" \
      "$prefixedApp/share/dbus-1/services/com.test.Svc.service" \
      || fail "the D-Bus service does not launch through the prefixed shim"
    grep -q "$prefixedApp/bin/sb-svcapp --daemon" \
      "$prefixedApp/share/systemd/user/svcapp.service" \
      || fail "the systemd unit does not launch through the prefixed shim"
    plone="$prefixedApp/share/applications/com.test.Prefixed.desktop"
    grep -qx "Exec=$prefixedApp/bin/sb-svcapp %U" "$plone" \
      || fail "the desktop Exec does not use the prefixed shim"
    grep -q '^Name=.* (sb)$' "$plone" \
      || fail "the menu entry name is not suffixed with the prefix label"
    grep -qx 'Name=New' "$plone" \
      || fail "the [Desktop Action] name was suffixed too, only the entry name should be"

    touch "$XDG_RUNTIME_DIR/confine-shared/marker" "$XDG_RUNTIME_DIR/host-secret"
    export CONFINE_HOSTVAR=host-copied CONFINE_DECLARED=host-loses
    "$offlineApp/bin/env" > observed || fail "the sandbox did not run"

    mkdir -p "$HOME/data/repo/.git/hooks"
    "$guardedApp/bin/touch" "$HOME/data/repo/file" \
      || fail "a writable bind with a read only pattern inside it became read only"
    "$guardedApp/bin/touch" "$HOME/data/repo/.git/hooks/pre-commit" 2>/dev/null || true
    [ -e "$HOME/data/repo/.git/hooks/pre-commit" ] \
      && fail "a read only pattern inside a writable bind could be written"

    CONFINE_NETWORK_SETUP=probe "$offlineApp/bin/env" > refused 2>&1 \
      && fail "a launch asking for an undeclared network setup started anyway"
    grep -q 'has no network setup named probe' refused \
      || fail "an undeclared network setup failed for the wrong reason: $(cat refused)"

    "$offlineApp/bin/ls" "$XDG_RUNTIME_DIR/confine-shared" > rtdir \
      || fail "the xdg-run bind did not resolve against the runtime dir"
    grep -qx marker rtdir || fail "the bound runtime directory is empty inside"
    "$offlineApp/bin/ls" "$XDG_RUNTIME_DIR" > rtroot
    grep -qx host-secret rtroot \
      && fail "an unbound runtime dir entry leaked into the sandbox"
    grep -qx ipc-link rtroot || fail "the declared symlink was not created"

    grep -qx 'CONFINE_HOSTVAR=host-copied' observed \
      || fail "envPassthrough did not copy the host value"
    grep -qx 'CONFINE_LIST=a,b,c' observed \
      || fail "a comma valued declared env did not arrive intact"
    grep -qx 'CONFINE_DECLARED=declared-wins' observed \
      || fail "declared env did not reach the sandbox or lost to envPassthrough"
    grep -qx "PATH=${pkgs.coreutils}/bin:/run/current-system/sw/bin" observed \
      || fail "PATH is not what the launcher set"
    grep -q '^SSH_AUTH_SOCK=' observed \
      && fail "an agent socket leaked through --clearenv"

    cu=${pkgs.coreutils}/bin

    # Flatpak writes only the user and the overflow id, the host's other accounts stay out.
    "$accountsApp/bin/bash" -c "$cu/cat /etc/passwd" > passwd-inside || fail "the accounts sandbox did not run"
    [ "$(wc -l < passwd-inside)" = 2 ] || fail "the sandbox passwd is not just the user and nfsnobody: $(cat passwd-inside)"
    grep -q "^$(id -un):x:$(id -u):" passwd-inside || fail "the sandbox passwd lacks the user"
    grep -q '^nfsnobody:x:65534:' passwd-inside || fail "the sandbox passwd lacks the overflow id"
    "$hostAccountsApp/bin/bash" -c "$cu/cat /etc/passwd" > passwd-host
    cmp -s passwd-host /etc/passwd || fail "hostAccounts = true does not show the host's passwd"

    # The kernel half of the lock holds with seccomp off, and nesting lifts it.
    "$usernsLockedApp/bin/bash" -c "${pkgs.util-linux}/bin/unshare -U $cu/true" 2>/dev/null \
      && fail "a sandbox without nesting could still create a user namespace"
    "$usernsOpenApp/bin/bash" -c "${pkgs.util-linux}/bin/unshare -U $cu/true" \
      || fail "nesting = true no longer allows a user namespace"

    # An app that may create namespaces is the admin of a network it makes, and gets no use of that.
    printf '%s\n' home-netlink=ok own-netlink=EPERM own-netlink-generic=EPERM early-netlink-tc=EPERM ioctl-read=ok \
      ioctl-interface=EPERM ioctl-bridge=EPERM raw-socket=EPERM tcp-socket=ok option-ipsec=EPERM option-repair=EPERM \
      option-plain=ok sysctl=EROFS > guard-want
    "$guardedNamespacesApp/bin/bash" -c "$guardProbe/bin/guard-probe" > guard-got \
      || fail "the probe did not run under the namespace guard: $(cat guard-got)"
    diff -u guard-want guard-got || fail "the namespace guard let something through or refused too much"
    "$usernsOpenApp/bin/bash" -c "$guardProbe/bin/guard-probe" > guard-off || fail "the probe did not run unguarded"
    grep -qx own-netlink=ok guard-off && grep -qx ioctl-interface=ok guard-off && grep -qx raw-socket=ok guard-off \
      || fail "the probe proves nothing, left unguarded it cannot administer its own network either: $(tr '\n' ' ' < guard-off)"

    mkdir -p "$HOME/data/repo/.git/hooks" "$HOME/data/nohooks/.git"
    printf '[core]\n' > "$HOME/data/repo/.git/config"
    printf '[core]\n' > "$HOME/data/nohooks/.git/config"
    "$gitApp/bin/bash" -c "
      cd '$HOME/data/repo'
      $cu/mv .git .git-old 2>/dev/null && echo renamed
      $cu/touch .git/hooks/post-checkout 2>/dev/null && echo hook
      { echo '[core] fsmonitor = x' >> .git/config; } 2>/dev/null && echo config
      echo /elsewhere > .git/commondir && echo commondir
      $cu/mkdir .git/hooks/inner 2>/dev/null && echo inner
      $cu/mkdir '$HOME/data/nohooks/.git/hooks/x' 2>/dev/null && echo placeholder
      $cu/mkdir -p '$HOME/data/new/.git/hooks'
      printf '#!/bin/sh\n' > '$HOME/data/new/.git/hooks/pre-commit'
      $cu/chmod +x '$HOME/data/new/.git/hooks/pre-commit'
    " > git-results 2> git-stderr || fail "the git sandbox did not run: $(cat git-stderr)"
    [ "$(cat git-results)" = commondir ] || fail "a guarded repository could be changed: $(tr '\n' ' ' < git-results)"
    [ -d "$HOME/data/repo/.git" ] || fail "the guarded .git is gone"
    [ -e "$HOME/data/repo/.git/commondir" ] && fail "a commondir planted in a checkout survived the session"
    grep -q 'commondir (removed)' git-stderr || fail "the planted commondir was not reported"
    grep -q "$HOME/data/new/.git" git-stderr || fail "a repository made inside with a hook was not reported"

    mkdir -p "$TMPDIR/elsewhere" "$HOME/data/linked"
    ln -s "$TMPDIR/elsewhere" "$HOME/data/linked/.git"
    "$gitApp/bin/bash" -c true 2> linked-err && fail "a .git link inside a shared folder did not stop the launch"
    grep -q 'refusing to start' linked-err || fail "a .git link failed for the wrong reason: $(cat linked-err)"
    rm "$HOME/data/linked/.git"

    mkdir -p "$HOME/.config" "$HOME/Docs"
    touch "$HOME/Docs/doc-marker"
    # shellcheck disable=SC2016
    printf 'XDG_DOCUMENTS_DIR="$HOME/Docs"\n' > "$HOME/.config/user-dirs.dirs"
    "$xdgApp/bin/bash" -c "$cu/ls '$HOME/Docs'" > xdg-out || fail "the xdg-documents sandbox did not run"
    grep -qx doc-marker xdg-out || fail "xdg-documents did not resolve through user-dirs.dirs"

    status=0
    "$accountsApp/bin/bash" -c 'exit 7' || status=$?
    [ "$status" = 7 ] || fail "the app's exit status is lost: $status"
    status=0
    "$accountsApp/bin/bash" -c 'kill -TERM $$' || status=$?
    [ "$status" = 143 ] || fail "an app ended by a signal does not report 128 plus the signal: $status"
    "$accountsApp/bin/bash" -c "$cu/sleep 30" &
    launcher=$!
    $cu/sleep 1
    kill -TERM "$launcher"
    status=0
    wait "$launcher" || status=$?
    [ "$status" = 143 ] || fail "a launcher stopped with SIGTERM does not report it: $status"

    # An app may start the real program in the background and exit, which Flatpak keeps running.
    lingered="$HOME/.local/share/confine/com.test.Shell/lingered"
    status=0
    "$accountsApp/bin/bash" -c "{ $cu/sleep 2; $cu/readlink /proc/1/fd/2 > \"\$HOME/lingered\"; } < /dev/null > /dev/null 2>&1 & exit 3" 2> linger-err || status=$?
    [ "$status" = 3 ] || fail "an app that left a process running lost its own status: $status"
    [ -e "$lingered" ] && fail "the launch waited for the process the app left running"
    for _ in $(seq 100); do
      [ -e "$lingered" ] && break
      $cu/sleep 0.1
    done
    [ -e "$lingered" ] || fail "a process the app left running died with the app"
    # What runs on could otherwise reopen the caller's terminal through the sandbox's first process.
    [ "$(cat "$lingered")" = /dev/null ] || fail "the sandbox's first process still holds the caller's output: $(cat "$lingered")"
    for _ in $(seq 50); do
      [ -z "$(find "$XDG_RUNTIME_DIR/confine" -mindepth 1 -maxdepth 1 -name 'com.test.Shell.*' 2>/dev/null)" ] && break
      $cu/sleep 0.1
    done
    [ -z "$(find "$XDG_RUNTIME_DIR/confine" -mindepth 1 -maxdepth 1 -name 'com.test.Shell.*' 2>/dev/null)" ] \
      || fail "the sandbox was not cleaned up after its last process ended"

    instances() {
      find "$XDG_RUNTIME_DIR/confine" -mindepth 1 -maxdepth 1 -name "$1.*" 2>/dev/null
    }
    wait_cleaned() {
      for _ in $(seq 100); do
        [ -z "$(instances "$1")" ] && return 0
        $cu/sleep 0.1
      done
      return 1
    }

    # The launcher's helpers write to a pipe of its own, so whoever reads the launch's output waits for the app's processes alone.
    SECONDS=0
    captured=$("$accountsApp/bin/bash" -c "$cu/sleep 300 < /dev/null > /dev/null 2>&1 & echo early" 2>&1)
    [ "$captured" = early ] || fail "the output of an app that left a process running is wrong: $captured"
    [ "$SECONDS" -lt 20 ] || fail "reading the launch's output waited for the process the app left running"
    kill -TERM "$(sed -n 's/^launcher_pid=//p' "$XDG_RUNTIME_DIR"/confine/com.test.Shell.*/state)"
    wait_cleaned com.test.Shell || fail "the sandbox was not cleaned up after its launcher was stopped"
    [ "$(echo piped | "$accountsApp/bin/bash" -c "$cu/cat")" = piped ] || fail "the app does not read the caller's stdin"
    # What bwrap has to say still reaches the caller.
    "$brokenApp/bin/bash" -c true 2> broken-err && fail "a sandbox bwrap could not build started anyway"
    grep -q nonexistent-confine-path broken-err || fail "bwrap's own message was lost: $(cat broken-err)"

    # linger = false ends the sandbox with its app, for tools on a terminal that a process left behind could read from.
    tidied="$HOME/.local/share/confine/com.test.Tidy/lingered"
    status=0
    "$tidyApp/bin/bash" -c "{ $cu/sleep 1; $cu/touch \"\$HOME/lingered\"; } < /dev/null > /dev/null 2>&1 & exit 3" || status=$?
    [ "$status" = 3 ] || fail "an app with linger = false lost its status: $status"
    [ -z "$(instances com.test.Tidy)" ] || fail "linger = false returned before the sandbox was cleaned up"
    $cu/sleep 2
    [ -e "$tidied" ] && fail "linger = false let a process outlive the app"

    # Killed outright the launcher passes no signal on, and its sandbox must not run on without it.
    "$accountsApp/bin/bash" -c "$cu/sleep 300" &
    launcher=$!
    for _ in $(seq 100); do
      grep -qs '^pid=' "$XDG_RUNTIME_DIR"/confine/com.test.Shell.*/state && break
      $cu/sleep 0.1
    done
    kill -KILL "$launcher"
    wait "$launcher" 2>/dev/null || true
    wait_cleaned com.test.Shell || fail "killing the launcher outright left its sandbox running"

    # Whatever the caller left open besides stdin, stdout and stderr stays outside.
    "$accountsApp/bin/bash" -c '[ -e /proc/self/fd/9 ]' 9< "$HOME/.config/user-dirs.dirs" \
      && fail "a descriptor the caller left open reached the sandbox"

    # A message to a stderr nobody reads any more must not abort the launcher.
    mkfifo dead-stderr
    : < dead-stderr &
    status=0
    "$limitedApp/bin/bash" -c true 2> dead-stderr || status=$?
    [ "$status" = 1 ] || fail "the launcher did not survive a closed stderr: $status"

    # The audit only reports a .git link planted inside, a removal through it would land wherever it points.
    mkdir -p "$TMPDIR/outside-repo" "$HOME/data/planted"
    touch "$TMPDIR/outside-repo/commondir"
    "$gitApp/bin/bash" -c "$cu/ln -s '$TMPDIR/outside-repo' '$HOME/data/planted/.git'" 2> planted-err \
      || fail "the git sandbox did not run: $(cat planted-err)"
    [ -e "$TMPDIR/outside-repo/commondir" ] || fail "the audit removed a file through a planted .git link"
    grep -q "$HOME/data/planted/.git (a link)" planted-err || fail "a planted .git link was not reported: $(cat planted-err)"
    rm "$HOME/data/planted/.git"

    # kill 0 inside reaches the launcher's group, and the process that cleans up and audits must be out of its way,
    # first without a terminal, where the launcher has a group of its own, then as a terminal's foreground job.
    planted="$HOME/data/repo/.git/commondir"
    plant="echo /elsewhere > '$planted'; kill -KILL 0"
    status=0
    ( "$gitApp/bin/bash" -c "$plant"; exit "$?" ) 2> /dev/null || status=$?
    [ "$status" = 137 ] || fail "a sandbox that killed its process group ended with $status"
    for _ in $(seq 50); do
      [ -e "$planted" ] || break
      $cu/sleep 0.1
    done
    [ -e "$planted" ] && fail "killing the process group from inside skipped the git audit"
    wait_cleaned com.test.Git || fail "killing the process group from inside skipped the cleanup"
    ${pkgs.util-linux}/bin/script -qec "$gitApp/bin/bash -c \"[ -t 0 ] && $cu/touch '$HOME/data/on-terminal'; $plant\"" /dev/null > /dev/null 2>&1 || true
    [ -e "$HOME/data/on-terminal" ] || fail "the terminal job did not run on a terminal"
    for _ in $(seq 50); do
      [ -e "$planted" ] || break
      $cu/sleep 0.1
    done
    [ -e "$planted" ] && fail "killing a terminal job's process group from inside skipped the git audit"
    wait_cleaned com.test.Git || fail "killing a terminal job's process group from inside skipped the cleanup"

    # Ctrl+C reaches every process of the terminal's job, bwrap included, and is the app's to answer.
    interrupt() {
      (sleep 1; printf '\003'; sleep 4) | ${pkgs.util-linux}/bin/script -qec "$1" /dev/null 2>&1 | tr -d '\r'
    }
    interrupt "$accountsApp/bin/bash -c 'trap \"echo got-int\" INT; $cu/sleep 2; $cu/sleep 1; echo survived'" > interrupt-handled
    grep -q got-int interrupt-handled || fail "Ctrl+C did not reach the app: $(cat interrupt-handled)"
    grep -q survived interrupt-handled || fail "Ctrl+C ended a sandbox whose app handles it: $(cat interrupt-handled)"
    interrupt "$accountsApp/bin/bash -c '$cu/sleep 30'; echo status=\$?" > interrupt-default
    grep -q 'status=130' interrupt-default || fail "an app Ctrl+C ended does not report it: $(cat interrupt-default)"

    # Files handed over between @@ markers lose the markers, and one the sandbox already sees passes as it is.
    mkdir -p "$HOME/visible" "$TMPDIR/hidden"
    touch "$HOME/visible/seen" "$TMPDIR/hidden/unseen"
    "$forwardApp/bin/bash" -c 'printf "%s\n" "$@"' _ first @@ "$HOME/visible/seen" @@ @@u "file://$HOME/visible/seen" @@ last \
      > forwarded 2> forward-err || fail "the forwarding sandbox did not run: $(cat forward-err)"
    [ "$(tr '\n' ' ' < forwarded)" = "first $HOME/visible/seen file://$HOME/visible/seen last " ] \
      || fail "forwarding changed what the sandbox already sees: $(tr '\n' ' ' < forwarded)"
    # The build has no document portal, so the file goes through unchanged and the launcher says why.
    "$forwardApp/bin/bash" -c 'printf "%s\n" "$@"' _ @@ "$TMPDIR/hidden/unseen" @@ > forwarded 2> forward-err
    [ "$(cat forwarded)" = "$TMPDIR/hidden/unseen" ] || fail "an unforwardable file did not pass unchanged: $(cat forwarded)"
    grep -q 'could not hand .* to the document portal' forward-err || fail "a failed forward is not reported"

    # The portal takes an app without the network share for offline.
    "$onlineApp/bin/bash" -c "$cu/cat /.flatpak-info" > online-info 2> /dev/null || fail "the online sandbox did not run"
    grep -qx 'shared=network;' online-info || fail "an app with network access does not tell the portal: $(cat online-info)"
    "$forwardApp/bin/bash" -c "$cu/cat /.flatpak-info" > offline-info 2> /dev/null
    grep -q '^shared=' offline-info && fail "an app without network access claims one to the portal"

    # Limits that cannot be applied must stop the launch rather than be dropped, and the build has no user manager.
    "$limitedApp/bin/bash" -c true 2> limited-err && fail "an app with resource limits started without its scope"
    grep -q 'refusing to start without the scope that carries the resource limits' limited-err \
      || fail "the missing scope failed for the wrong reason: $(cat limited-err)"

    unix_socket "$rt/wayland-0"
    "$contextApp/bin/bash" -c true 2> context-err && fail "a Wayland app started when the compositor gave no security context"
    grep -q 'refusing to start without one' context-err \
      || fail "a refused security context failed for the wrong reason: $(cat context-err)"
    rm "$rt/wayland-0"

    pone="$portalApp/share/applications/com.test.Portal.desktop"
    grep -qx "Exec=$portalApp/bin/svcapp @@u %U @@" "$pone" \
      || fail "a portal app's desktop entry does not fence its URLs for forwarding: $(grep ^Exec "$pone")"
    grep -qx "Exec=$portalApp/bin/svcapp --new" "$pone" \
      || fail "an Exec without field codes was changed"
    grep -q '@@' "$outPath/share/applications/com.test.Svc.desktop" \
      && fail "an app without portals got forwarding markers"

    left=$(find "$XDG_RUNTIME_DIR/confine" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    [ "$left" -eq 0 ] || fail "$left instance directories survived the run"

    appdir="$XDG_RUNTIME_DIR/app/com.test.Launcher"
    [ -d "$appdir" ] || fail "the per-application runtime directory was not created"
    [ "$(stat -c %a "$appdir")" = 700 ] || fail "the per-application directory is not private"

    echo "launcher behaviour: all checks passed" > "$out"
  ''
