{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.virtualisation.lab;
  inherit (cfg) modes;
  sandboxed = cfg.sandbox != null;

  guestMount = pkgs.writeShellScriptBin "guest-mount" ''
    mkdir -p "$HOME/guest"
    exec memprocfs -device "''${VM_INSPECT_DEVICE:?}" -mount "$HOME/guest" "$@"
  '';

  guestGdb = pkgs.writeShellScriptBin "guest-gdb" ''
    exec gdb -ex "target remote ''${VM_INSPECT_GDB:?}" "$@"
  '';

  guestPs = pkgs.writeShellScriptBin "guest-ps" ''
    if [ "$#" -gt 0 ]; then
      echo "usage: guest-ps"
      echo "The processes of a Windows guest as its memory holds them, which no program in it decides."
      echo "When the session was opened with --control, what the guest itself lists is held against it."
      exit 2
    fi
    mount=$(mktemp -d)
    listed=1
    guest-exec tasklist /fo csv /nh > "$mount.guest" 2>/dev/null || listed=0
    memprocfs -device "''${VM_INSPECT_DEVICE:?}" -mount "$mount" > "$mount.log" 2>&1 &
    reader=$!
    trap 'fusermount3 -u "$mount" 2>/dev/null; kill "$reader" 2>/dev/null; rmdir "''${mount:?}" 2>/dev/null; rm -f "''${mount:?}".*' EXIT
    tries=0
    until [ -s "$mount/sys/proc/proc.txt" ]; do
      if [ "$tries" -ge 120 ] || ! kill -0 "$reader" 2>/dev/null; then
        echo "guest-ps: the guest's memory gave no list of processes" >&2
        tail -n 3 "$mount.log" >&2
        exit 1
      fi
      sleep 0.5
      tries=$((tries + 1))
    done
    echo "guest-ps: read from the guest's memory, T marks a process that has ended" >&2
    LC_ALL=C tr -cd '\11\12\40-\176' < "$mount/sys/proc/proc.txt" | cut -c1-76 | tee "$mount.memory"
    if [ "$listed" -eq 0 ]; then
      exit 0
    fi
    awk 'NR == 1 { pid = index($0, "Pid") + 2; flag = index($0, "Flag"); next }
         /^-+ / && substr($0, flag, 5) !~ /T/ { print substr($0, pid - 6, 7) + 0 }' "$mount.memory" | sort -u > "$mount.memory.pids"
    LC_ALL=C tr -cd '\11\12\40-\176' < "$mount.guest" | awk -F '","' 'NF > 2 { print $2 + 0 }' | sort -u > "$mount.guest.pids"
    hidden=$(comm -23 "$mount.memory.pids" "$mount.guest.pids" | tr '\n' ' ')
    echo >&2
    if [ -z "$hidden" ]; then
      echo "guest-ps: the guest itself lists every process that is in its memory" >&2
    else
      echo "guest-ps: the guest was asked a moment before its memory was read, so a process that began in between shows here too" >&2
      echo "in memory, not listed by the guest: $hidden"
    fi
  '';

  labBox = pkgs.writeShellScriptBin "lab-box" ''
    usage() {
      echo "usage: lab-box [--rw DIR]... [--ro PATH]... [--chdir DIR] [--setenv NAME VALUE]... [--share-loopback] [--] COMMAND..." >&2
      echo "Runs COMMAND with no guest, no network and no files but the Nix store, an empty /tmp and the paths named." >&2
      echo "  --share-loopback  keep the lab's loopback, to reach a server the caller runs" >&2
      exit 2
    }
    realpath=${pkgs.coreutils}/bin/realpath
    inside=
    IFS=: read -ra folders <<< "$PATH"
    for folder in "''${folders[@]}"; do
      folder=$("$realpath" -q -- "$folder") || continue
      case "$folder" in /nix/store/*) inside+=''${inside:+:}$folder ;; esac
    done
    args=(
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
      --die-with-parent --new-session --clearenv
      --ro-bind /nix/store /nix/store --proc /proc --dev /dev --tmpfs /tmp
      --setenv HOME /tmp --setenv PATH "$inside"
    )
    net=--unshare-net
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --rw) [ "$#" -ge 2 ] || usage; args+=(--bind "$2" "$2"); shift ;;
        --ro) [ "$#" -ge 2 ] || usage; args+=(--ro-bind "$2" "$2"); shift ;;
        --chdir) [ "$#" -ge 2 ] || usage; args+=(--chdir "$2"); shift ;;
        --setenv) [ "$#" -ge 3 ] || usage; args+=(--setenv "$2" "$3"); shift 2 ;;
        --share-loopback)
          ${
            if sandboxed then
              ''
                if [ -n "''${VM_LAB_ONLINE:-}" ]; then
                  echo "lab-box: this lab is online, so its loopback comes with the network. Start the lab without --online." >&2
                  exit 2
                fi
              ''
            else
              ''
                echo "lab-box: this lab has no sandbox, so its loopback is the system's own and comes with the network." >&2
                exit 2
              ''
          }
          net=
          ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
      esac
      shift
    done
    [ "$#" -gt 0 ] || usage
    program=$(type -P -- "$1") || program=
    # Followed only as far as the store, which the box has, since a program that goes by several names tells by the one it is started under.
    for _ in 1 2 3 4 5 6 7 8; do
      folder=$("$realpath" -q -- "$(${pkgs.coreutils}/bin/dirname -- "$program")") || break
      program=$folder/''${program##*/}
      case "$program" in /nix/store/*) break ;; esac
      [ -L "$program" ] || break
      target=$(${pkgs.coreutils}/bin/readlink -- "$program")
      case "$target" in /*) program=$target ;; *) program=$folder/$target ;; esac
    done
    if [ ! -f "$program" ] || [ ! -x "$program" ]; then
      echo "lab-box: $1 not found" >&2
      exit 127
    fi
    shift
    set -- "$program" "$@"
    exec ${pkgs.util-linux}/bin/setpriv --ambient-caps=-all --inh-caps=-all -- \
      ${pkgs.bubblewrap}/bin/bwrap "''${args[@]}" $net -- "$@"
  '';

  tools = pkgs.buildEnv {
    name = "vm-lab-tools";
    paths = [
      pkgs.memprocfs
      pkgs.gdb
      pkgs.radare2
      pkgs.memprocfs.symbolGateway
      guestMount
      guestGdb
      guestPs
      (pkgs.callPackage ./_guest-dbg/guest-dbg.nix { })
      labBox
      config.my.virtualisation.inspect.guestTools
    ]
    ++ map (tool: tool.package) (lib.attrValues cfg.tools);
  };
  toolsDrv = builtins.unsafeDiscardStringContext tools.drvPath;
  toolsOut = builtins.unsafeDiscardStringContext tools.outPath;
  toolsAttr = "${config.my.flakePath}#nixosConfigurations.${config.networking.hostName}.config.system.build.vmLabTools";

  launchers = lib.optionals sandboxed (
    map
      (v: {
        key = lib.concatStrings [
          (if v.online then "o" else "-")
          (if v.x11 then "x" else "-")
          (if v.full then "f" else "-")
          v.mode
        ];
        path = cfg.sandbox {
          inherit (v) online x11 full;
          kept = if v.mode == "-" then { } else modes.${v.mode}.kept;
        };
      })
      (
        lib.cartesianProduct {
          online = [ false true ];
          x11 = [ false true ];
          full = [ false true ];
          mode = [ "-" ] ++ lib.attrNames modes;
        }
      )
  );

  entry =
    width: name: summary:
    let
      lines = lib.splitString "\n" (lib.removeSuffix "\n" summary);
      label = "  ${name}";
    in
    lib.concatStringsSep "\n" (
      [ "${label}${lib.strings.replicate (lib.max 1 (width - lib.stringLength label)) " "}${lib.head lines}" ]
      ++ map (line: "${lib.strings.replicate width " "}${line}") (lib.tail lines)
    );

  # Inside its own user and mount namespace either way, so that what mounts the guest's memory needs no helper that runs as root.
  enter = if sandboxed then ''"$launcher" unshare'' else "${pkgs.util-linux}/bin/unshare";

  path = "\${VM_LAB_PATH:+$VM_LAB_PATH:}$VM_LAB_TOOLS/bin:$PATH";

  bashrc = pkgs.writeText "vm-lab-bashrc" ''
    if [ -f /etc/bashrc ]; then . /etc/bashrc; fi
    PATH=${path}
    PS1="\[\e[36m\][vm-lab $VM_INSPECT_DOMAIN]\[\e[0m\] $PS1"
  '';

  vmLab = pkgs.writeShellScriptBin "vm-lab" ''
    usage() {
      echo "usage: vm-lab ${lib.optionalString sandboxed "[--online] [--x11] [--full] "}[--control] [--join] [--tool INSTALLABLE]... DOMAIN [COMMAND...]"
      ${lib.concatMapStrings (name: ''
        echo "       vm-lab --${name} [--join] DOMAIN [ARGUMENT...]"
      '') (lib.attrNames modes)}
      ${
        if sandboxed then
          ''
            echo "A sandboxed shell, or COMMAND, with a running guest open for inspection."
            echo "The folder it starts in is read only inside, ./out is writable when it exists, ~/cache is kept between runs."
            echo "  --online   give the lab a network, it has none otherwise"
            echo "  --x11      let it draw on the X server"
            echo "  --full     no limit on memory, tasks and processor share"
          ''
        else
          ''
            echo "A shell, or COMMAND, with a running guest open for inspection and the lab's tools on its path."
            echo "This system runs it without a sandbox: your files and the network are in reach of whatever handles the guest's data in it."
          ''
      }
      echo "  --control  let the session send keys and pointer events to the guest and talk to the agent in it"
      echo "  --join     only enter a session that is open already, and open none"
      ${lib.concatStrings (lib.mapAttrsToList (name: mode: ''
        printf '%s\n' ${lib.escapeShellArg (entry 13 "--${name}" mode.summary)}
      '') modes)}
      echo "  --tool     a package to have inside, such as nixpkgs#binwalk"
      echo "A ./lab.nix in the starting folder is built and put on the path, as nix-shell does with shell.nix."
      echo "Windows debug symbols come from Microsoft through a gateway outside the lab that fetches nothing else, kept in ~/.cache/vm-lab/symbols."
      echo "Inside:"
      echo "  guest-mount   the guest's memory as files under ~/guest (MemProcFS), runs until stopped"
      echo "  guest-gdb     gdb on QEMU's debug stub, the guest stops while it is attached"
      echo "  guest-ps      the processes of a Windows guest as its memory holds them, held against what the guest lists"
      echo "  guest-dbg     breakpoints and watchpoints in one process, from outside: the guest sees no debugger"
      echo "  guest-shot    a picture of the guest's screen, from QEMU or from the frames Looking Glass shares,"
      echo "                or with --window of one window as the guest draws it, and with --crop a part of either"
      echo "  guest-input   keys and pointer events for the guest, in a session opened with --control"
      echo "  guest-agent   one command for the agent in the guest, in a session opened with --control"
      echo "  guest-exec    a program in the guest, as its logged in user with --as-user, left to run with --job"
      echo "  guest-py      a Python script of this side with the Python the guest has, with the same options"
      echo "  guest-job, guest-wait, guest-windows"
      echo "                follow what was left to run, wait for a process, a file or a window, list the windows"
      echo "  guest-read, guest-push, guest-pull, guest-ls, guest-stat, guest-hash, guest-grep, guest-find, guest-status"
      echo "                files and facts of the guest through its agent, each explains itself with --help"
      ${lib.concatStrings (lib.mapAttrsToList (name: tool: ''
        printf '%s\n' ${lib.escapeShellArg (entry 16 name tool.summary)}
      '') cfg.tools)}
      echo "  lab-box       run a program without the guest, the network or your files"
      exit "''${1:-2}"
    }
    online=- x11=- full=- mode=- control= join= extra=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        ${lib.optionalString sandboxed ''
          --online) online=o ;;
          --x11) x11=x ;;
          --full) full=f ;;
        ''}
        --control) control=1 ;;
        --join) join=1 ;;
        ${lib.concatMapStrings (name: ''
          --${name}) mode=${name} ;;
        '') (lib.attrNames modes)}
        --tool)
          [ "$#" -ge 2 ] || usage
          extra+=("$2")
          shift
          ;;
        -h | --help) usage 0 ;;
        --) shift; break ;;
        -*) echo "vm-lab: unknown option $1" >&2; exit 2 ;;
        *) break ;;
      esac
      shift
    done
    [ "$#" -ge 1 ] || usage
    domain=$1
    shift

    links="''${XDG_CACHE_HOME:-$HOME/.cache}/vm-lab"
    ${pkgs.coreutils}/bin/mkdir -p "$links"
    nix=${config.nix.package}/bin/nix
    if ! "$nix" build ${toolsOut} --out-link "$links/tools" 2>/dev/null \
      && ! "$nix" build '${toolsDrv}^out' --out-link "$links/tools" 2>/dev/null \
      && ! "$nix" build ${lib.escapeShellArg toolsAttr} --out-link "$links/tools"; then
      echo "vm-lab: could not get the lab's tools" >&2
      exit 1
    fi
    export VM_LAB_TOOLS=${toolsOut}

    sockets="''${XDG_RUNTIME_DIR:?}/vm-lab"
    symbols="$links/symbols"
    ${pkgs.coreutils}/bin/mkdir -p "$sockets" "$symbols"
    for stale in "$sockets"/symbols.*.sock; do
      owner=''${stale##*/symbols.}
      if [ -e "$stale" ] && ! kill -0 "''${owner%.sock}" 2>/dev/null; then
        ${pkgs.coreutils}/bin/rm -f "$stale"
      fi
    done
    export PDBCRUST_SYMBOL_SOCKET="$sockets/symbols.$$.sock"
    ${pkgs.bubblewrap}/bin/bwrap --unshare-all --share-net --die-with-parent --new-session --clearenv \
      --ro-bind /nix/store /nix/store --proc /proc --dev /dev --tmpfs /tmp \
      --ro-bind /etc/resolv.conf /etc/resolv.conf \
      --bind "$sockets" "$sockets" --bind "$symbols" "$symbols" \
      --setenv SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      -- "$VM_LAB_TOOLS/bin/pdb-symbol-gateway" "$PDBCRUST_SYMBOL_SOCKET" "$symbols" </dev/null &
    for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
      if [ -S "$PDBCRUST_SYMBOL_SOCKET" ]; then break; fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    if [ ! -S "$PDBCRUST_SYMBOL_SOCKET" ]; then
      echo "vm-lab: the symbol gateway did not start, so Windows debug symbols will be missing" >&2
      unset PDBCRUST_SYMBOL_SOCKET
    fi

    path=()
    add() {
      local out
      for out in "$@"; do
        if [ -d "$out/bin" ]; then path+=("$out/bin"); fi
      done
    }
    for tool in "''${extra[@]}"; do
      mapfile -t built < <("$nix" build --no-link --print-out-paths "$tool")
      if [ "''${#built[@]}" -eq 0 ]; then
        echo "vm-lab: could not get $tool" >&2
        exit 1
      fi
      add "''${built[@]}"
    done
    VM_LAB_ENV=
    if [ -f ./lab.nix ]; then
      mapfile -t built < <("$nix" build --no-link --print-out-paths -f ./lab.nix)
      if [ "''${#built[@]}" -eq 0 ]; then
        echo "vm-lab: ./lab.nix did not build" >&2
        exit 1
      fi
      add "''${built[@]}"
      VM_LAB_ENV=''${built[0]}
    fi
    VM_LAB_PATH=$(IFS=:; echo "''${path[*]}")
    VM_LAB_ONLINE=
    if [ "$online" = o ]; then VM_LAB_ONLINE=1; fi
    export VM_LAB_PATH VM_LAB_ENV VM_LAB_ONLINE

    ${
      if sandboxed then
        ''
            folder=$(pwd -P)
            account=$(${pkgs.getent}/bin/getent passwd "$(${pkgs.coreutils}/bin/id -u)" | ${pkgs.coreutils}/bin/cut -d: -f6)
            shared=1
            for home in "$HOME" "$account"; do
              case "$home/" in "$folder"/*) shared=0 ;; esac
              case "$folder/" in "$home"/.*) shared=0 ;; esac
            done
            if [ "$folder" = / ] || [ "$shared" = 0 ]; then
              ${pkgs.coreutils}/bin/mkdir -p "$links/empty"
              cd "$links/empty" || exit 1
              note="no folder is shared, start it in a folder of your home that is not hidden to have its files inside"
            elif [ -d out ]; then
              note="$folder is read only inside, its out folder is writable"
            else
              note="$folder is read only inside, create an out folder in it for a place to write"
            fi
        ''
      else
        ''
          note="there is no sandbox on this system: your files and the network are in reach of whatever handles the guest's data"
        ''
    }

    ${lib.concatStrings (
      lib.mapAttrsToList (name: mode: ''
        if [ "$mode" = ${name} ]; then
          ${lib.concatMapStrings (state: ''
            ${pkgs.coreutils}/bin/mkdir -p "''${XDG_STATE_HOME:-$HOME/.local/state}"/${lib.escapeShellArg state}
          '') (lib.attrNames mode.kept)}
          ${mode.start}
        fi
      '') modes
    )}

    if [ "$#" -eq 0 ]; then
      set -- "''${SHELL:-/bin/sh}"
      case "''${1##*/}" in
        fish)
          set -- "$1" --init-command 'set -gx PATH (string split -n : -- "$VM_LAB_PATH") $VM_LAB_TOOLS/bin $PATH; functions -q fish_prompt; and functions -c fish_prompt __vm_lab_prompt; function fish_prompt; set_color cyan; echo -n "[vm-lab $VM_INSPECT_DOMAIN] "; set_color normal; functions -q __vm_lab_prompt; and __vm_lab_prompt; end'
          ;;
        bash) set -- "$1" --rcfile ${bashrc} -i ;;
      esac
      echo "vm-lab: $domain is open in this shell, exit closes it"
      echo "vm-lab: $note"
    fi

    ${lib.optionalString sandboxed ''
      if [ "$full" = - ] && ! ${config.systemd.package}/bin/busctl --user call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping >/dev/null 2>&1; then
        echo "vm-lab: no user manager to carry the limits, as inside another sandbox, so it starts without them" >&2
        full=f
      fi

      case "$online$x11$full$mode" in
        ${lib.concatMapStrings (l: ''
          ${l.key}) launcher=${l.path} ;;
        '') launchers}
      esac
    ''}

    id=${pkgs.coreutils}/bin/id
    inspect=${config.my.virtualisation.inspect.package}/bin/vm-inspect
    session=(--gdb)
    if [ -n "$control" ]; then session+=(--control); fi
    if "$inspect" --join "$domain" -- ${pkgs.coreutils}/bin/true 2>/dev/null; then
      session=(--join)
    elif [ -n "$join" ]; then
      echo "vm-lab: $domain is not open, and with --join none is opened" >&2
      exit 1
    fi
    exec "$inspect" "''${session[@]}" "$domain" -- ${enter} \
      --user --map-user="$($id -u)" --map-group="$($id -g)" --mount --keep-caps -- \
      /bin/sh -c 'PATH=${path} exec "$@"' sh "$@"
  '';
in
{
  options.my.virtualisation.lab = {
    enable = mkEnableOption ''
      vm-lab, a shell around a guest that vm-inspect has open, with the guest's memory, the tools that read it and the
      guest tools. In a sandbox it has no network and none of the user's files but the folder it starts in, read only,
      which makes it the place to handle what comes out of a guest. It needs my.virtualisation.inspect
    '';

    sandbox = mkOption {
      type = types.nullOr (types.functionTo types.str);
      default = null;
      description = ''
        The sandbox vm-lab runs in. A function from what was asked for, the booleans online, x11 and full and the
        folders a mode keeps, to the program that runs its arguments as a command inside a sandbox made for that. A
        module that has a sandbox to offer sets it. With null, which is what remains without one, vm-lab only opens the
        guest and puts the tools on the path, so whatever handles the guest's data there has the user's files and the
        network in reach, and lab-box is the one barrier left.
      '';
    };

    limits = mkOption {
      type = types.attrsOf (types.either types.str types.int);
      default = {
        MemoryMax = "32G";
        TasksMax = 4096;
        CPUWeight = 50;
      };
      description = "What a sandboxed lab may use, in the names systemd has for it. vm-lab --full starts one without these.";
    };

    tools = mkOption {
      default = { };
      description = "More tools for the lab's path, each added by a module of its own under the name it is called by.";
      type = types.attrsOf (
        types.submodule {
          options = {
            package = mkOption {
              type = types.package;
              description = "What holds the tool.";
            };

            summary = mkOption {
              type = types.lines;
              description = "What the tool is, for vm-lab's help.";
            };
          };
        }
      );
    };

    modes = mkOption {
      default = { };
      description = ''
        More ways to start the lab, each added by a module of its own. vm-lab --NAME DOMAIN ARGUMENT... starts the lab
        in the mode of that name. Without such a module vm-lab has none.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            summary = mkOption {
              type = types.lines;
              description = "What the mode is, for vm-lab's help.";
            };

            kept = mkOption {
              type = types.attrsOf types.str;
              default = { };
              example = {
                lab-notes = ".notes";
              };
              description = ''
                Folders that only this mode has and that are kept between runs. Each is a folder below the user's state
                folder, by name, and the place in the lab's home where it shows. It takes a sandbox.
              '';
            };

            start = mkOption {
              type = types.lines;
              description = ''
                Shell that runs outside the lab right before it starts, as a part of vm-lab. It finds the guest's name
                in $domain, the lab's folder below the runtime folder, which the lab sees read only, in $sockets, and
                what followed DOMAIN as its arguments. It names the command to run inside with set --. Setting
                control=1 opens the session with control of the guest.
              '';
            };
          };
        }
      );
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = vmLab;
      description = "vm-lab itself, exposed for wrapping it and for testing outside a switch.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.my.virtualisation.inspect.enable or false;
        message = "my.virtualisation.lab works in a vm-inspect session, so it needs the vm-inspect module and its my.virtualisation.inspect.enable.";
      }
      {
        assertion = lib.all (
          name:
          builtins.match "[a-z][a-z0-9-]*" name != null
          && !lib.elem name [ "online" "x11" "full" "control" "join" "tool" "help" ]
        ) (lib.attrNames modes);
        message = "my.virtualisation.lab.modes: a name is lower case letters, digits and dashes, and none of vm-lab's own options.";
      }
    ];

    system.build.vmLabTools = tools;

    environment.systemPackages = [ vmLab ];

    my.persistence.home.directories = [
      ".cache/vm-lab"
      ".local/state/vm-inspect"
    ];
  };
}
