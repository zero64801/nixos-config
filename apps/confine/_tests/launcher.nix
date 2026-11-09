# nix build --impure --no-link --expr 'import ./apps/confine/_tests/launcher.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

let
  inherit (pkgs) lib;
  wrap = pkgs.callPackage ../_lib/wrap.nix { };

  base = {
    package = pkgs.coreutils;
    binaries = [ "env" ];
    appId = "com.test.Launcher";
  };

  scriptOf =
    settings:
    let
      w = wrap (base // settings);
    in
    "${w.launcher}/bin/${w.launcher.name}";

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

  multiDesktop = wrap {
    package = pkgs.foot;
    appId = "com.test.MultiDesktop";
  };
in
pkgs.runCommand "confine-launcher-behaviour"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.xdg-dbus-proxy
    ];

    plainScript = scriptOf { };
    audioScript = scriptOf {
      profile = [
        "gui"
        "audio"
      ];
    };
    # Several ports render as a comma list, which shellcheck rejects unquoted.
    isolatedScript = scriptOf {
      portals = true;
      network = "isolated";
      networkPorts.toHost = [
        3000
        2081
      ];
      networkPorts.fromHost = [ "0.0.0.0/8000" ];
    };
    tunnelScript = scriptOf {
      network = "isolated";
      networkSetups.probe = pkgs.writeShellScript "probe-setup" "true";
    };
    isolatedX11Script = scriptOf {
      profile = [
        "gui"
        "gpu"
      ];
      x11 = "isolated";
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
    gitApp = shell {
      appId = "com.test.Git";
      binds.rw = [ "data" ];
      gitGuard.enable = true;
    };
    xdgApp = shell {
      appId = "com.test.Xdg";
      binds.ro = [ "xdg-documents" ];
    };
    nestingScript = scriptOf { seccomp.nesting = true; };
    unscopedScript = scriptOf { scope = false; };
    devicesScript = scriptOf { devices = [ "/dev/hidraw*" ]; };
    keysScript = scriptOf {
      devices = [ "/dev/hidraw*" ];
      securityKeys = true;
    };
  }
  ''
    fail() { echo "confine: $1" >&2; exit 1; }

    # A literal fd number collided with the D-Bus sync pipe and the pulse config.
    grep -q -- '--seccomp 10' "$audioScript" \
      && fail "the seccomp descriptor is a literal again"
    grep -q 'confine_seccomp_fd' "$audioScript" \
      || fail "the seccomp descriptor is no longer allocated"
    # The script's own comments mention the flag, so strip them first.
    grep -vE '^[[:space:]]*#' "$audioScript" | grep -q -- '--ro-bind-data' \
      && fail "pulse is back on a descriptor, which pasta closes"

    env_line=$(grep -n 'CONFINE_DECLARED' "${scriptOf { env.CONFINE_DECLARED = "x"; }}" | head -1 | cut -d: -f1)
    pass_line=$(grep -n 'for var in TERM LANG' "${scriptOf { env.CONFINE_DECLARED = "x"; }}" | head -1 | cut -d: -f1)
    [ -n "$env_line" ] && [ -n "$pass_line" ] || fail "could not locate the env blocks"
    [ "$env_line" -gt "$pass_line" ] \
      || fail "declared env is emitted before the host passthrough and loses to it"

    grep -q 'timeout 10 cat "$instance/info"' "$isolatedScript" \
      || fail "the bwrapinfo read is unbounded again"

    # Without a security context KWin offers sandboxed clients fake input, screen capture and background clipboard reads.
    grep -q '/bin/confine-security-context "$runtime_dir/$context_socket" confine' "$audioScript" \
      || fail "a Wayland app starts without a security context"
    grep -q -- '--setenv CONFINE_WAYLAND_SANDBOXED 1' "$audioScript" \
      || fail "nested launches cannot tell they already sit in a security context"
    grep -q 'refusing to start without one' "$audioScript" \
      || fail "a refused security context no longer stops the launch"
    grep -q 'zen-beta "$instance_id"' "${scriptOf { profile = [ "gui" ]; waylandAppId = "zen-beta"; }}" \
      || fail "waylandAppId does not reach the compositor"
    grep -q 'confine-security-context' "${scriptOf { profile = [ "gui" ]; waylandSecurityContext = false; }}" \
      && fail "waylandSecurityContext = false still creates a context"
    grep -q 'confine-security-context' "$plainScript" \
      && fail "an app without Wayland creates a security context"

    grep -q 'probe) export CONFINE_NETWORK_SETUP_BIN=' "$tunnelScript" \
      || fail "a declared network setup cannot be selected"
    grep -qx 'unset CONFINE_NETWORK_SETUP_BIN' "$tunnelScript" \
      || fail "an inherited CONFINE_NETWORK_SETUP_BIN is not cleared"
    # Anything the setup leaves running would otherwise hold the seccomp and info descriptors.
    setup_line=$(grep -n 'CONFINE_NETWORK_SETUP_BIN:-' "$tunnelScript" | head -1 | cut -d: -f1)
    seccomp_line=$(grep -n 'exec {confine_seccomp_fd}' "$tunnelScript" | head -1 | cut -d: -f1)
    [ -n "$setup_line" ] && [ -n "$seccomp_line" ] || fail "could not locate the network setup"
    [ "$setup_line" -lt "$seccomp_line" ] \
      || fail "the network setup runs after the sandbox descriptors are open"
    # resolved's socket would carry lookups around the tunnel.
    grep '^args=(' "$tunnelScript" | grep -q 'systemd/resolve' \
      && fail "the resolved socket is bound unconditionally"
    grep -A1 'if \[ -z "${"$"}{CONFINE_NETWORK_SETUP_BIN:-}" \]; then' "$tunnelScript" \
      | grep -q -- '--ro-bind-try /run/systemd/resolve' \
      || fail "the resolved socket is not bound for launches without a network setup"

    grep -q -- "-t '0.0.0.0/8000' -u '0.0.0.0/8000'" "$isolatedScript" \
      || fail "a string networkPorts entry is not passed to pasta as given"

    for f in share/dbus-1/services/com.test.Svc.service \
             share/systemd/user/svcapp.service \
             etc/xdg/autostart/svcapp.desktop; do
      grep -q "$unwrappedService/bin" "$outPath/$f" \
        && fail "$f still launches the unwrapped binary"
      grep -q "$outPath/bin" "$outPath/$f" \
        || fail "$f does not point at the wrapper"
    done

    grep -q 'satellite_args' "$isolatedX11Script" \
      || fail "the isolated X11 path no longer builds its arguments as expected"
    sed -n '/satellite_args=(/,/^        )/p' "$isolatedX11Script" > sat || true
    sed -n '/satellite_args+=(/,/^          )/p' "$isolatedX11Script" >> sat || true
    grep -q -- '--dev-bind-try /dev/dri' sat \
      || fail "the isolated X server is not given the GPU, so GLX will fail"
    grep -q -- '--ro-bind-try /run/opengl-driver' sat \
      || fail "the isolated X server is not given the driver tree"

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

    export HOME="$TMPDIR/home" XDG_RUNTIME_DIR="$TMPDIR/rt"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR/confine-shared"
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

    # A server's socket is only shareable if the directory it writes to is host-backed, bind(2) refuses to create one at an existing name.
    grep -q -- '--bind "$runtime_dir/app/com.test.Shared" "$runtime_dir"' \
      "${scriptOf { appId = "com.test.Shared"; runtimeDir = "shared"; }}" \
      || fail "runtimeDir = shared does not back the runtime dir with the app directory"
    grep -q -- '--dir "$runtime_dir"' "$plainScript" \
      || fail "the default runtime dir is no longer private"
    # The build sandbox's /bin/sh is a bind mount, not a link, so only the generated loop can be checked here.
    grep -q 'for fhs_dir in /bin /usr/bin; do' "$plainScript" \
      || fail "sandboxes no longer get the host's /bin and /usr/bin links"
    grep -q -- '--remount-ro "$fhs_dir"' "$plainScript" \
      || fail "the /bin and /usr/bin links became writable inside the sandbox"

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

    grep -q -- '--disable-userns' "$plainScript" || fail "sandboxes without nesting lost the kernel namespace lock"
    grep -q -- '--disable-userns' "$nestingScript" && fail "nesting = true still disables user namespaces"
    grep -q 'systemd-run --user --scope' "$plainScript" || fail "apps no longer get a scope of their own"
    grep -q 'systemd-run' "$unscopedScript" && fail "scope = false still creates a scope"
    grep -q 'SRANDOM' "$plainScript" || fail "instance ids are no longer random"
    grep -q 'is_security_key' "$devicesScript" || fail "device wildcards no longer leave security keys out"
    grep -q 'is_security_key' "$keysScript" && fail "securityKeys = true still filters security keys"

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
