{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  jq,
  systemd,
  util-linux,
  helpers,
  index,
}:

writeShellApplication {
  name = "confine";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    jq
    systemd
    util-linux
  ];

  text = ''
    index=${index}
    runtime_dir=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

    die() {
      echo "confine: $*" >&2
      exit 1
    }

    usage() {
      cat <<'EOF'
    usage: confine COMMAND [ARGS]

      list                      the installed apps
      info APP [--json]         what APP may reach
      ps                        the running sandboxes
      run [--command=CMD] APP [ARGS...]
                                start APP, or CMD inside APP's sandbox
      enter INSTANCE|APP [CMD...]
                                run CMD (default sh) inside a running sandbox,
                                under the same seccomp filter and without privileges
      kill INSTANCE|APP         stop a running sandbox and everything in it

    APP is an app's name, its app id or its attribute in confine.apps.
    EOF
      exit "''${1:-2}"
    }

    state_get() {
      sed -n "s/^$2=//p" "$1" | tail -n 1
    }

    resolve_app() {
      local key
      key=$(jq -r --arg q "$1" \
        'to_entries[] | select(.key == $q or .value.appId == $q or .value.permissions.name == $q) | .key' \
        "$index" | head -n 1)
      [ -n "$key" ] || die "no app named $1, see confine list"
      printf '%s' "$key"
    }

    # A launcher killed outright leaves its folder behind, the live ones still run their launcher script.
    live_instances() {
      local dir launcher launcher_pid
      for dir in "$runtime_dir"/confine/*.[0-9]*; do
        [ -f "$dir/state" ] || continue
        launcher=$(state_get "$dir/state" launcher)
        launcher_pid=$(state_get "$dir/state" launcher_pid)
        if [ -n "$launcher_pid" ] && [ -r "/proc/$launcher_pid/cmdline" ] \
          && tr '\0' '\n' < "/proc/$launcher_pid/cmdline" | grep -qxF -- "$launcher"; then
          printf '%s\n' "$dir"
        else
          rm -rf "$dir"
          # Only confine's own portal entry, Flatpak's always hold a .ref lock.
          local flatpak_dir="$runtime_dir/.flatpak/''${dir##*.}"
          if [ -d "$flatpak_dir" ] && [ ! -e "$flatpak_dir/.ref" ]; then
            rm -rf "$flatpak_dir"
          fi
        fi
      done
    }

    matching_instances() {
      local dir
      while IFS= read -r dir; do
        if [ "''${dir##*.}" = "$1" ] || [ "$(state_get "$dir/state" app)" = "$1" ] \
          || [ "$(state_get "$dir/state" name)" = "$1" ]; then
          printf '%s\n' "$dir"
        fi
      done < <(live_instances)
    }

    cmd_list() {
      jq -r 'to_entries[] | [.key, .value.appId, .value.main] | @tsv' "$index" \
        | column -t -s $'\t' -N NAME,APP-ID,COMMAND
    }

    cmd_info() {
      local key
      [ "$#" -ge 1 ] || usage
      key=$(resolve_app "$1")
      if [ "''${2:-}" = --json ]; then
        jq --arg k "$key" '.[$k]' "$index"
        return
      fi
      jq -r --arg k "$key" '
        def yn: if . then "yes" else "no" end;
        def list: if (. // []) == [] then "-" else map(if type == "object" then "\(.from) as \(.to)" else tostring end) | join(", ") end;
        .[$k] as $a | $a.permissions as $p |
        "App            \($a.appId) (\($k))",
        "Command        \($a.main)",
        "Network        \($p.network | if . == true then "host" elif . == false then "none" else tostring end)"
          + (if $p.network == "isolated" then ", to host \($p.networkPorts.toHost | list), from host \($p.networkPorts.fromHost | list)" else "" end),
        "Wayland        \($p.wayland | yn)" + (if $p.wayland and $p.waylandSecurityContext then ", in a security context" else "" end),
        "X11            \($p.x11)",
        "Audio          pipewire \($p.pipewire | yn), pulse \($p.pulse | yn)",
        "GPU            \($p.gpu | yn)",
        "Devices        \($p.devices | list)" + (if $p.securityKeys then ", security keys allowed" else "" end),
        "Home           \($p.home)" + (if $p.home == "private" then ", ~/.local/share/confine/\($a.appId)" else "" end),
        "Accounts       \(if $p.hostAccounts then "the host passwd and group" else "generated" end)",
        "Work folder    \($p.workdir // "-")",
        "Read and write \($p.binds.rw | list)",
        "Read only      \($p.binds.ro | list)",
        "Git guard      \(if $p.gitGuard.enable then "on, \($p.gitGuard.depth) levels deep" else "off" end)",
        "Portals        \($p.portals | yn)",
        "Session bus    \(if $p.dbus.filter then "filtered" else "UNFILTERED" end), talks to \($p.dbus.session.talk | list), owns \($p.dbus.session.own | list)",
        "System bus     talks to \($p.dbus.system.talk | list)",
        "Accessibility  \($p.a11y | yn)",
        "Seccomp        " + (if $p.seccomp.enable then "on" + ([ "nesting", "devel", "multiarch", "bluetooth", "can", "ioUring" ] | map(select($p.seccomp[.])) | if . == [] then "" else ", allows " + join(", ") end) else "OFF" end),
        "Scope          \($p.scope | yn)" + (if ($p.resources // {}) == {} then "" else ", " + ($p.resources | to_entries | map("\(.key)=\(.value)") | join(" ")) end),
        "Environment    sets \($p.env | keys | list), passes \($p.envPassthrough | list)"
      ' "$index"
    }

    cmd_ps() {
      local dir
      {
        printf 'INSTANCE\tAPP-ID\tPID\tSCOPE\n'
        while IFS= read -r dir; do
          printf '%s\t%s\t%s\t%s\n' "''${dir##*.}" "$(state_get "$dir/state" app)" \
            "$(state_get "$dir/state" pid)" "$(state_get "$dir/state" scope)"
        done < <(live_instances)
      } | column -t -s $'\t'
    }

    cmd_run() {
      local command="" key launcher
      while [[ "''${1:-}" == --command=* ]]; do
        command=''${1#--command=}
        shift
      done
      [ "$#" -ge 1 ] || usage
      key=$(resolve_app "$1")
      shift
      launcher=$(jq -r --arg k "$key" '.[$k].launcher' "$index")
      [ -n "$command" ] || command=$(jq -r --arg k "$key" '.[$k].main' "$index")
      exec "$launcher" "$command" "$@"
    }

    cmd_enter() {
      local dirs dir pid filter env_pid inner envs=()
      [ "$#" -ge 1 ] || usage
      mapfile -t dirs < <(matching_instances "$1")
      shift
      [ "''${#dirs[@]}" -gt 0 ] || die "no running sandbox matches, see confine ps"
      [ "''${#dirs[@]}" -eq 1 ] || die "several sandboxes match, name one by its instance: ''${dirs[*]##*.}"
      dir=''${dirs[0]}
      pid=$(state_get "$dir/state" pid)
      filter=$(state_get "$dir/state" filter)
      [ -n "$pid" ] && [ -d "/proc/$pid" ] || die "the sandbox has no recorded pid yet"

      # bwrap's init still holds the launcher's environment, the app below it has the sandbox's.
      env_pid=$(cut -d' ' -f1 "/proc/$pid/task/$pid/children" 2>/dev/null) || env_pid=""
      [ -n "$env_pid" ] || env_pid=$pid
      mapfile -d "" envs < "/proc/$env_pid/environ"

      [ "$#" -gt 0 ] || set -- sh
      inner=(${coreutils}/bin/env -i "''${envs[@]}" "$@")
      if [ -n "$filter" ]; then
        inner=(${helpers}/bin/confine-seccomp-exec "$filter" "''${inner[@]}")
      fi
      # Joining as the same uid leaves no capabilities after exec, and no_new_privs keeps file capabilities from adding any.
      exec nsenter --target "$pid" --user --mount --pid --net --ipc --uts --cgroup --root --wd --preserve-credentials -- \
        ${util-linux}/bin/setpriv --no-new-privs --inh-caps=-all --ambient-caps=-all -- \
        "''${inner[@]}"
    }

    cmd_kill() {
      local dirs dir scope launcher_pid
      [ "$#" -eq 1 ] || usage
      mapfile -t dirs < <(matching_instances "$1")
      [ "''${#dirs[@]}" -gt 0 ] || die "no running sandbox matches, see confine ps"
      for dir in "''${dirs[@]}"; do
        scope=$(state_get "$dir/state" scope)
        launcher_pid=$(state_get "$dir/state" launcher_pid)
        if [ -n "$scope" ] && systemctl --user stop "$scope" 2>/dev/null; then
          continue
        fi
        kill -TERM "$launcher_pid" 2>/dev/null || true
      done
    }

    [ "$#" -ge 1 ] || usage
    command=$1
    shift
    case "$command" in
      list) cmd_list ;;
      info) cmd_info "$@" ;;
      ps) cmd_ps ;;
      run) cmd_run "$@" ;;
      enter) cmd_enter "$@" ;;
      kill) cmd_kill "$@" ;;
      -h | --help | help) usage 0 ;;
      *) usage ;;
    esac
  '';
}
