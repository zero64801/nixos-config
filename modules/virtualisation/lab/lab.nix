{ config, lib, pkgs, ... }:

let
  limits = {
    MemoryMax = "32G";
    TasksMax = 4096;
    CPUWeight = 50;
  };

  guestMount = pkgs.writeShellScriptBin "guest-mount" ''
    mkdir -p "$HOME/guest"
    exec memprocfs -device "''${VM_INSPECT_DEVICE:?}" -mount "$HOME/guest" "$@"
  '';

  guestGdb = pkgs.writeShellScriptBin "guest-gdb" ''
    exec gdb -ex "target remote ''${VM_INSPECT_GDB:?}" "$@"
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
          if [ -n "''${VM_LAB_ONLINE:-}" ]; then
            echo "lab-box: this lab is online, so its loopback comes with the network. Start the lab without --online." >&2
            exit 2
          fi
          net=
          ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
      esac
      shift
    done
    [ "$#" -gt 0 ] || usage
    if ! program=$(command -v -- "$1") || ! program=$("$realpath" -q -- "$program"); then
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
      labBox
    ];
  };
  toolsDrv = builtins.unsafeDiscardStringContext tools.drvPath;
  toolsOut = builtins.unsafeDiscardStringContext tools.outPath;
  toolsAttr = "${config.my.flakePath}#nixosConfigurations.${config.networking.hostName}.config.system.build.vmLabTools";

  appId = "org.nixos.VmLab";

  base = {
    package = pkgs.runCommand "vm-lab-env" { } "mkdir -p $out/bin";
    name = "vm-lab";
    inherit appId;
    home = "ephemeral";
    linger = false;
    workdir = "ro";

    seccomp = {
      nesting = true;
      devel = true;
    };
    devices = [ "/dev/fuse" ];

    binds.rw = [
      "./out"
      {
        from = "xdg-cache/vm-lab/work";
        to = "cache";
      }
    ];
    binds.ro = [
      "xdg-run/vm-inspect"
      "xdg-run/vm-lab"
      "/run/vm-inspect"
    ];
    env.__NIXOS_SET_ENVIRONMENT_DONE = "1";
    envPassthrough = [
      "COLORTERM"
      "VM_INSPECT_DOMAIN"
      "VM_INSPECT_DIR"
      "VM_INSPECT_DEVICE"
      "VM_INSPECT_GDB"
      "VM_LAB_TOOLS"
      "VM_LAB_PATH"
      "VM_LAB_ENV"
      "VM_LAB_ONLINE"
      "PDBCRUST_SYMBOL_SOCKET"
    ];
  };

  launchers = map (
    v:
    let
      w = config.confine.lib.wrap (
        base
        // lib.optionalAttrs v.online { network = "isolated"; }
        // lib.optionalAttrs v.x11 { x11 = "host"; }
        // lib.optionalAttrs (!v.full) { resources = limits; }
      );
    in
    {
      key = lib.concatStrings [
        (if v.online then "o" else "-")
        (if v.x11 then "x" else "-")
        (if v.full then "f" else "-")
      ];
      path = "${w.launcher}/bin/${w.launcher.name}";
    }
  ) (lib.cartesianProduct {
    online = [ false true ];
    x11 = [ false true ];
    full = [ false true ];
  });

  path = "\${VM_LAB_PATH:+$VM_LAB_PATH:}$VM_LAB_TOOLS/bin:$PATH";

  bashrc = pkgs.writeText "vm-lab-bashrc" ''
    if [ -f /etc/bashrc ]; then . /etc/bashrc; fi
    PATH=${path}
    PS1="\[\e[36m\][vm-lab $VM_INSPECT_DOMAIN]\[\e[0m\] $PS1"
  '';

  vmLab = pkgs.writeShellScriptBin "vm-lab" ''
    usage() {
      echo "usage: vm-lab [--online] [--x11] [--full] [--tool INSTALLABLE]... DOMAIN [COMMAND...]"
      echo "A sandboxed shell, or COMMAND, with a running guest open for inspection."
      echo "The folder it starts in is read only inside, ./out is writable when it exists, ~/cache is kept between runs."
      echo "  --online   give the lab a network, it has none otherwise"
      echo "  --x11      let it draw on the X server"
      echo "  --full     no limit on memory, tasks and processor share"
      echo "  --tool     a package to have inside, such as nixpkgs#binwalk"
      echo "A ./lab.nix in the starting folder is built and put on the path, as nix-shell does with shell.nix."
      echo "Windows debug symbols come from Microsoft through a gateway outside the lab that fetches nothing else, kept in ~/.cache/vm-lab/symbols."
      echo "Inside:"
      echo "  guest-mount   the guest's memory as files under ~/guest (MemProcFS), runs until stopped"
      echo "  guest-gdb     gdb on QEMU's debug stub, the guest stops while it is attached"
      echo "  lab-box       run a program without the guest, the network or your files"
      exit "''${1:-2}"
    }
    online=- x11=- full=- extra=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --online) online=o ;;
        --x11) x11=x ;;
        --full) full=f ;;
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

    if [ "$full" = - ] && ! ${config.systemd.package}/bin/busctl --user call org.freedesktop.systemd1 \
      /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping >/dev/null 2>&1; then
      echo "vm-lab: no user manager to carry the limits, as inside another sandbox, so it starts without them" >&2
      full=f
    fi

    case "$online$x11$full" in
      ${lib.concatMapStrings (l: ''
        ${l.key}) launcher=${l.path} ;;
      '') launchers}
    esac

    id=${pkgs.coreutils}/bin/id
    inspect=${config.my.virtualisation.inspect.package}/bin/vm-inspect
    mode=--gdb
    if "$inspect" --join "$domain" -- ${pkgs.coreutils}/bin/true 2>/dev/null; then
      mode=--join
    fi
    exec "$inspect" "$mode" "$domain" -- "$launcher" \
      unshare --user --map-user="$($id -u)" --map-group="$($id -g)" --mount --keep-caps -- \
      /bin/sh -c 'PATH=${path} exec "$@"' sh "$@"
  '';
in
lib.mkIf config.my.virtualisation.inspect.enable {
  system.build.vmLabTools = tools;

  environment.systemPackages = [ vmLab ];

  my.persistence.home.directories = [ ".cache/vm-lab" ];
}
