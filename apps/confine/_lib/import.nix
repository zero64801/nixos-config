{
  writeShellApplication,
  util,
  flatpak,
}:

# One-shot paste output, an upstream permission change can never quietly
# alter a build. remote-info reports what ships after Flathub review.
writeShellApplication {
  name = "confine-import";
  runtimeInputs = [ flatpak ];

  text = ''
    ${util.cliPrelude}

    remote=flathub
    app_id=""

    usage() {
      echo -e "''${bold}confine-import''${reset} — turn a Flathub app's permissions into a confine block

    ''${green}''${bold}Usage:''${reset} confine-import [OPTIONS] APP_ID

    ''${bold}Options:''${reset}
      --remote NAME   Flatpak remote to query (default: flathub)

    ''${bold}Example:''${reset}
      confine-import com.discordapp.Discord

    Output is a starting point, not a finished sandbox. Anything that could not
    be translated is reported as a comment rather than dropped silently."
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --remote)
          [ "$#" -ge 2 ] || die "--remote needs a value"
          remote=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)
          [ -z "$app_id" ] || die "only one application id at a time"
          app_id=$1; shift ;;
      esac
    done

    # Output is pasted into Nix, a bare quote or ''${ evaluates on the user's machine.
    esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g'; }

    [ -n "$app_id" ] || { usage; exit 1; }

    meta=$(mktemp)
    trap 'rm -f "$meta"' EXIT

    info "Fetching $app_id from $remote"
    flatpak remote-info --show-metadata "$remote" "$app_id" > "$meta" 2>/dev/null \
      || die "no metadata for $app_id on $remote"

    # remote-info metadata is ini.
    value() {
      awk -v want="[$1]" -v key="$2" '
        $0 == want { inside = 1; next }
        /^\[/      { inside = 0 }
        inside && index($0, key "=") == 1 { print substr($0, length(key) + 2) }
      ' "$meta"
    }

    pairs() {
      awk -v want="[$1]" '
        $0 == want { inside = 1; next }
        /^\[/      { inside = 0 }
        inside && /=/ { print }
      ' "$meta"
    }

    # Flatpak packs list values as semicolon separated.
    items() { tr ';' '\n' | grep -v '^$' || true; }

    profiles=()
    scalars=()
    devices=()
    ro=()
    rw=()
    talk=()
    own=()
    system_talk=()
    envs=()
    notes=()

    add_profile() {
      local p
      for p in ''${profiles[@]+"''${profiles[@]}"}; do
        [ "$p" = "$1" ] && return 0
      done
      profiles+=("$1")
    }

    wants_x11=false

    while IFS= read -r s; do
      case "$s" in
        network)
          # Host networking reaches every service on 127.0.0.1, isolated is the safer default.
          scalars+=("network = \"isolated\";")
          ;;
        ipc) notes+=("shared=ipc was dropped: the sandbox always gets its own IPC namespace") ;;
        *) notes+=("unmapped shared: $s") ;;
      esac
    done < <(value Context shared | items)

    while IFS= read -r s; do
      case "$s" in
        wayland) add_profile gui ;;
        x11|fallback-x11) wants_x11=true ;;
        pulseaudio) add_profile audio ;;
        session-bus) notes+=("sockets=session-bus asks for the unfiltered session bus; the names below are filtered instead") ;;
        system-bus) notes+=("sockets=system-bus asks for the unfiltered system bus; name what it needs under dbus.system.talk") ;;
        ssh-auth) notes+=("sockets=ssh-auth would hand over the SSH agent; left out deliberately") ;;
        gpg-agent) notes+=("sockets=gpg-agent would hand over the GPG agent; left out deliberately") ;;
        cups) notes+=("sockets=cups (printing) has no confine equivalent yet") ;;
        pcsc) notes+=("sockets=pcsc (smartcard) has no confine equivalent") ;;
        *) notes+=("unmapped socket: $s") ;;
      esac
    done < <(value Context sockets | items)

    if [ "$wants_x11" = true ]; then
      # The host display would let the app read every other window's input.
      add_profile gui
      scalars+=("x11 = \"isolated\";")
    fi

    while IFS= read -r d; do
      case "$d" in
        dri) add_profile gpu ;;
        input) devices+=("/dev/input") ;;
        kvm) devices+=("/dev/kvm") ;;
        shm) notes+=("devices=shm was dropped: shared memory needs an IPC namespace this sandbox does not share") ;;
        all)
          add_profile gpu
          notes+=("devices=all asks for every device node, which is most of what a sandbox is for; only the GPU was granted, add specific nodes if something is missing")
          ;;
        *) notes+=("unmapped device: $d") ;;
      esac
    done < <(value Context devices | items)

    map_filesystem() {
      local spec=$1 mode=rw path
      case "$spec" in
        *:ro)     mode=ro; spec=''${spec%:ro} ;;
        *:rw)     spec=''${spec%:rw} ;;
        *:create) spec=''${spec%:create} ;;
      esac

      case "$spec" in
        host|host-os|host-etc|/|/home|/home/*)
          notes+=("filesystems=$spec covers the whole host and was not translated")
          return ;;
        home)
          notes+=("filesystems=home is the entire home directory; set home = \"host\" only if you mean it")
          return ;;
        # ~/.local/share holds the private home of every other confined app.
        xdg-config|xdg-data|xdg-cache)
          notes+=("filesystems=$spec is that entire directory in the real home, not a subpath; name what the app needs instead")
          return ;;
        xdg-run/pipewire-0)
          add_profile audio
          return ;;
        # Kept verbatim, the launcher resolves it against the runtime dir.
        xdg-run/*)
          path="$spec" ;;
        xdg-download*)  path="Downloads''${spec#xdg-download}" ;;
        xdg-documents*) path="Documents''${spec#xdg-documents}" ;;
        xdg-pictures*)  path="Pictures''${spec#xdg-pictures}" ;;
        xdg-videos*)    path="Videos''${spec#xdg-videos}" ;;
        xdg-music*)     path="Music''${spec#xdg-music}" ;;
        xdg-desktop*)   path="Desktop''${spec#xdg-desktop}" ;;
        xdg-public-share*) path="Public''${spec#xdg-public-share}" ;;
        xdg-config*)    path=".config''${spec#xdg-config}" ;;
        xdg-data*)      path=".local/share''${spec#xdg-data}" ;;
        xdg-cache*)     path=".cache''${spec#xdg-cache}" ;;
        # Bracketed to match a literal tilde, not a home expansion.
        [~]/*)          path="''${spec:2}" ;;
        /*)             path="$spec" ;;
        *)
          notes+=("unmapped filesystem: $spec")
          return ;;
      esac

      if [ "$mode" = ro ]; then ro+=("$path"); else rw+=("$path"); fi
    }

    while IFS= read -r f; do
      map_filesystem "$f"
    done < <(value Context filesystems | items)

    while IFS= read -r line; do
      case "''${line#*=}" in
        talk) talk+=("''${line%%=*}") ;;
        own)  own+=("''${line%%=*}") ;;
        *)    notes+=("session bus policy for ''${line%%=*} is ''${line#*=}, which has no confine equivalent") ;;
      esac
    done < <(pairs "Session Bus Policy")

    while IFS= read -r line; do
      case "''${line#*=}" in
        talk|own) system_talk+=("''${line%%=*}") ;;
        *) notes+=("system bus policy for ''${line%%=*} was not translated") ;;
      esac
    done < <(pairs "System Bus Policy")

    while IFS= read -r line; do
      # /run/host exists only inside a Flatpak, the value would point at nothing here.
      case "''${line#*=}" in
        */run/host/*)
          notes+=("''${line%%=*} refers to /run/host, which is Flatpak-only, and was dropped")
          continue ;;
      esac
      envs+=("''${line%%=*} = \"$(esc "''${line#*=}")\";")
    done < <(pairs Environment)

    # Electron ships Chromium, whose zygote needs a nested user namespace.
    if value Application base | grep -qi electron; then
      add_profile chromium
    fi

    for t in ''${talk[@]+"''${talk[@]}"}; do
      case "$t" in
        org.kde.StatusNotifierWatcher|com.canonical.*) add_profile tray ;;
      esac
    done

    emit_list() {
      local name=$1 v; shift
      [ "$#" -gt 0 ] || return 0
      echo "  $name = ["
      for v in "$@"; do printf '    "%s"\n' "$(esc "$v")"; done
      echo "  ];"
    }

    echo
    if [ "''${#notes[@]}" -gt 0 ]; then
      echo -e "''${yellow}# Not translated, decide these yourself:''${reset}"
      printf '#   %s\n' "''${notes[@]}"
      echo
    fi

    # The last component is not always a Nix identifier, 7-zip needs quoting.
    name=''${app_id##*.}
    name=''${name,,}
    if [[ $name =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      attr=$name
    else
      attr="\"$(esc "$name")\""
    fi

    echo "nyx.confine.apps.$attr = {"
    echo "  package = pkgs.CHANGEME;"
    echo "  appId = \"$(esc "$app_id")\";"
    [ "''${#profiles[@]}" -gt 0 ] && echo "  profile = [ $(printf '"%s" ' "''${profiles[@]}")];"
    for s in ''${scalars[@]+"''${scalars[@]}"}; do echo "  $s"; done
    emit_list "devices" ''${devices[@]+"''${devices[@]}"}
    emit_list "binds.ro" ''${ro[@]+"''${ro[@]}"}
    emit_list "binds.rw" ''${rw[@]+"''${rw[@]}"}
    emit_list "dbus.session.talk" ''${talk[@]+"''${talk[@]}"}
    emit_list "dbus.session.own" ''${own[@]+"''${own[@]}"}
    emit_list "dbus.system.talk" ''${system_talk[@]+"''${system_talk[@]}"}
    if [ "''${#envs[@]}" -gt 0 ]; then
      echo "  env = {"
      printf '    %s\n' "''${envs[@]}"
      echo "  };"
    fi
    echo "};"
  '';
}
