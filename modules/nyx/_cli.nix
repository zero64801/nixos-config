{
  writeShellApplication,
  util,
  coreutils,
  ncurses,
  nix,
  nixos-rebuild,
  flakePath ? null,
  hostName ? null,
}:

writeShellApplication {
  name = "nyx";

  runtimeInputs = [
    coreutils
    ncurses
    nix
    nixos-rebuild
  ];

  text = ''
    set -euo pipefail

    FLAKE_PATH="''${NYX_FLAKE_PATH:-${if flakePath != null then flakePath else ""}}"
    HOST="''${NYX_HOST:-${if hostName != null then hostName else ""}}"

    ${util.cliPrelude}

    ensure_flake() {
      [[ -n "$FLAKE_PATH" ]] || die "FLAKE_PATH not set. Set nyx.flakePath or NYX_FLAKE_PATH."
      [[ -d "$FLAKE_PATH" ]] || die "Flake directory not found: $FLAKE_PATH"
      [[ -n "$HOST" ]]       || die "HOST not set. Set NYX_HOST."
    }

    rebuild() {
      local verb="$1"
      shift
      ensure_flake
      if [[ "$verb" == "build" ]]; then
        info "Building ''${bold}$HOST''${reset}..."
        # nixos-rebuild has no --out-link, so build in a temp dir to keep ./result out of the caller's cwd
        local build_tmp flake_abs
        build_tmp=$(mktemp -d)
        trap 'rm -rf "$build_tmp"' EXIT
        flake_abs=$(realpath "$FLAKE_PATH")
        (cd "$build_tmp" && nixos-rebuild build --flake "$flake_abs#$HOST" "$@")
      else
        info "Running nixos-rebuild ''${bold}$verb''${reset} for ''${bold}$HOST''${reset}..."
        sudo nixos-rebuild "$verb" --flake "$FLAKE_PATH#$HOST" "$@"
      fi
    }

    delegate() {
      local tool="$1" module="$2"
      shift 2
      command -v "$tool" >/dev/null 2>&1 || die "$tool not found. Enable $module."
      exec "$tool" "$@"
    }

    cmd_update() {
      ensure_flake
      if command -v nyx-pin >/dev/null 2>&1; then
        exec nyx-pin update "$@"
      fi
      info "nyx-pin not available, running plain flake update..."
      nix flake update --flake "$FLAKE_PATH" "$@"
    }

    cmd_clean() {
      local older_than="7d"
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --older-than)
            [[ "$#" -ge 2 ]] || die "--older-than requires a value. Usage: nyx clean [--older-than 7d]"
            older_than="$2"; shift 2 ;;
          -*) die "Unknown flag: $1. Usage: nyx clean [--older-than 7d]" ;;
          *) older_than="$1"; shift ;;
        esac
      done
      info "Deleting generations older than ''${bold}$older_than''${reset} and collecting garbage..."
      sudo nix-collect-garbage --delete-older-than "$older_than"
    }

    cmd_diff() {
      ensure_flake
      DIFF_TMP=$(mktemp -d)
      trap 'rm -rf "$DIFF_TMP"' EXIT
      info "Building system closure for ''${bold}$HOST''${reset}..."
      nix build "$FLAKE_PATH#nixosConfigurations.$HOST.config.system.build.toplevel" \
        --out-link "$DIFF_TMP/result"
      nix store diff-closures /run/current-system "$DIFF_TMP/result"
    }

    cmd_repl() {
      ensure_flake
      exec nix repl --expr "builtins.getFlake \"$FLAKE_PATH\""
    }

    show_help() {
      echo -e "''${bold}nyx''${reset} — NixOS system management

''${green}''${bold}Usage:''${reset} nyx [COMMAND] [ARGS]

''${green}''${bold}Commands:''${reset}
  ''${yellow}switch [args]''${reset}              Rebuild and activate the system now.
  ''${yellow}boot [args]''${reset}                Rebuild and activate on next boot.
  ''${yellow}test [args]''${reset}                Rebuild and activate without a boot entry.
  ''${yellow}build [args]''${reset}               Build the system without activating.
  ''${yellow}update [inputs...]''${reset}         Update flake inputs. Delegates to nyx-pin so
                             pinned and frozen inputs are preserved.
  ''${yellow}pin <args>''${reset}                 Manage flake input pins (nyx-pin).
  ''${yellow}persist <args>''${reset}             Manage impermanence paths (nyx-persist).
  ''${yellow}clean [--older-than 7d]''${reset}    Delete old generations and collect garbage.
  ''${yellow}diff''${reset}                       Build the system and diff it against the running one.
  ''${yellow}repl''${reset}                       Open nix repl with the flake loaded.
  ''${yellow}help''${reset}                       Show this help message.

Extra arguments to switch/boot/test/build are passed to nixos-rebuild.

''${green}''${bold}Environment:''${reset}
  ''${yellow}NYX_FLAKE_PATH''${reset}   Override the flake path ''${DIM}(current: $FLAKE_PATH)''${NC}
  ''${yellow}NYX_HOST''${reset}         Override the target host ''${DIM}(current: $HOST)''${NC}
"
      exit 0
    }

    main() {
      if [[ "$#" == '0' ]]; then
        show_help
      fi

      case "$1" in
        -h|--help|help)
          show_help
          ;;
        switch|boot|test|build)
          rebuild "$@"
          ;;
        update|up)
          shift
          cmd_update "$@"
          ;;
        pin)
          shift
          delegate nyx-pin "nyx.pinning" "$@"
          ;;
        persist)
          shift
          delegate nyx-persist "nyx.impermanence" "$@"
          ;;
        clean|gc)
          shift
          cmd_clean "$@"
          ;;
        diff)
          shift
          cmd_diff "$@"
          ;;
        repl)
          shift
          cmd_repl "$@"
          ;;
        *)
          die "Unknown command: $1. Run 'nyx help' for usage."
          ;;
      esac
    }

    main "$@"
  '';
}
