{
  lib,
  wrap,
  runCommand,
  symlinkJoin,
  writeShellApplication,
  writeText,
  makeDesktopItem,
  coreutils,
  getent,
}:

{
  scratchDir,
  tint,
}:

let
  empty = runCommand "confined-terminal-env" { } "mkdir -p $out/bin";

  # Programs outside run these later from the same folder, direnv on cd and nix when it evaluates. confine's git guard covers the repositories.
  guards = [
    "./.envrc"
    "./.direnv"
    "./flake.nix"
    "./flake.lock"
    "./shell.nix"
    "./default.nix"
  ];

  base = {
    package = empty;
    name = "confined-terminal";
    appId = "app.confined.Terminal";
    home = "ephemeral";
    linger = false;
    network = "isolated";
    workdir = "rw";
    gitGuard.enable = true;
    binds.ro = [
      "/nix/var/nix/daemon-socket"
      "/lib64"
    ]
    ++ guards;
    env.NIX_REMOTE = "daemon";
    envPassthrough = [
      "NIX_PATH"
      "COLORTERM"
      "NIX_LD"
      "NIX_LD_LIBRARY_PATH"
    ];
  };

  launchers = map (
    v:
    let
      w = wrap (
        base
        // lib.optionalAttrs v.offline { network = "none"; }
        // lib.optionalAttrs v.keep { home = "host"; }
        // lib.optionalAttrs v.gui {
          wayland = true;
          gpu = true;
          sysfs = true;
        }
      );
    in
    {
      key = lib.concatStrings [
        (if v.offline then "o" else "-")
        (if v.keep then "k" else "-")
        (if v.gui then "g" else "-")
      ];
      path = "${w.launcher}/bin/${w.launcher.name}";
    }
  ) (lib.cartesianProduct {
    offline = [ false true ];
    keep = [ false true ];
    gui = [ false true ];
  });

  bashrc = writeText "confined-terminal-bashrc" ''
    if [ -f /etc/bashrc ]; then . /etc/bashrc; fi
    PS1="\[\e[31m\][confined]\[\e[0m\] $PS1"
  '';

  script = writeShellApplication {
    name = "confined";
    runtimeInputs = [
      coreutils
      getent
    ];
    text = ''
      offline=- keep=- gui=- folder=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --offline) offline=o ;;
          --keep) keep=k ;;
          --gui) gui=g ;;
          -h | --help)
            echo "usage: confined [--offline] [--keep] [--gui] [FOLDER]"
            echo "A throwaway sandboxed shell that sees only FOLDER, or the current folder, or a new scratch folder in ~/${scratchDir}."
            echo "  --offline  no network"
            echo "  --keep     keep this folder's sandbox home between runs"
            echo "  --gui      allow windows (Wayland and GPU)"
            exit 0
            ;;
          -*)
            echo "confined: unknown option $1" >&2
            exit 2
            ;;
          *)
            if [ -n "$folder" ]; then
              echo "confined: give one folder at most" >&2
              exit 2
            fi
            folder=$1
            ;;
        esac
        shift
      done

      # The account's home, since HOME may already point into another sandbox's home.
      home=$(realpath -e -- "$(getent passwd "$(id -u)" | cut -d: -f6)")
      folder=$(realpath -e -- "''${folder:-.}")
      if [ ! -d "$folder" ]; then
        echo "confined: $folder is not a folder" >&2
        exit 1
      fi
      if [ "$folder" = / ] || [[ "$home/" == "$folder"/* ]]; then
        folder="$home/${scratchDir}/$(date +%F-%H%M%S)"
        mkdir -p "$folder"
        echo "confined: new scratch folder $folder"
      elif [[ "$folder" == "$home"/.* ]]; then
        echo "confined: refusing to share $folder, the hidden folders of your home hold app data and keys" >&2
        exit 1
      fi

      if [ "$keep" = k ]; then
        HOME="$home/.local/state/confined-terminal/$(printf '%s' "$folder" | sha256sum | cut -c1-16)"
        mkdir -p "$HOME"
        export HOME
      fi

      case "$offline$keep$gui" in
        ${lib.concatMapStrings (l: ''
          ${l.key}) launcher=${l.path} ;;
        '') launchers}
      esac

      shell=$(getent passwd "$(id -u)" | cut -d: -f7)
      shell_args=()
      case "$(basename "$shell")" in
        fish)
          shell_args=(--init-command 'functions -q fish_prompt; and functions -c fish_prompt __confined_prompt; function fish_prompt; set_color red; echo -n "[confined] "; set_color normal; functions -q __confined_prompt; and __confined_prompt; end')
          ;;
        bash) shell_args=(--rcfile ${bashrc} -i) ;;
      esac

      old_background=""
      if [ -t 0 ] && [ -t 1 ]; then
        printf '\e]2;[confined] %s\a' "$folder"
        ${lib.optionalString (tint != null) ''
          # Only a terminal that reports its background gets tinted, so it can always be put back exactly.
          saved_tty=$(stty -g)
          stty -icanon -echo min 0 time 3
          printf '\e]11;?\a'
          reply=""
          IFS= read -r -d $'\a' reply || true
          stty "$saved_tty"
          case "$reply" in
            *']11;'*)
              old_background=''${reply#*]11;}
              old_background=''${old_background%%$'\e'*}
              printf '\e]11;%s\a' ${lib.escapeShellArg tint}
              ;;
          esac
        ''}
      fi

      cd "$folder"
      status=0
      "$launcher" "$shell" "''${shell_args[@]}" || status=$?

      if [ -t 1 ]; then
        if [ -n "$old_background" ]; then
          printf '\e]11;%s\a' "$old_background"
        fi
        printf '\e]2;\a'
      fi
      exit "$status"
    '';
  };

  desktopItem = makeDesktopItem {
    name = "confined-terminal";
    desktopName = "Terminal (Confined)";
    comment = "A throwaway sandboxed shell for code you don't trust";
    exec = "confined %f";
    terminal = true;
    icon = "utilities-terminal";
    categories = [
      "System"
      "Utility"
    ];
    mimeTypes = [ "inode/directory" ];
    keywords = [
      "sandbox"
      "shell"
      "confined"
    ];
  };
in
symlinkJoin {
  name = "confined-terminal";
  paths = [
    script
    desktopItem
  ];
  meta.mainProgram = "confined";
}
