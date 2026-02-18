{
  writeShellApplication,
  lib,
  coreutils,
  util-linux,
  findutils,
  gnugrep,
  gnused,
  rsync,
  jq,
  nix,
  fzf,
  bat,
  eza,
  persistentStoragePath ? "/persist/local",
  configRepoPath ? null,
  hostname ? "unknown",
  persistenceConfigPath ? null,
  masterPersistenceJson ? null,
}:

writeShellApplication {
  name = "nyx-persist";

  runtimeInputs = [
    coreutils
    util-linux
    findutils
    gnugrep
    gnused
    rsync
    jq
    nix
    fzf
    bat
    eza
  ];

  text = ''
    set -euo pipefail

    PERSIST_PATH="${persistentStoragePath}"
    CONFIG_REPO="${if configRepoPath != null then configRepoPath else ""}"
    HOSTNAME="${hostname}"
    # This is the local persist.json that we edit
    PERSIST_JSON_FILE="${if persistenceConfigPath != null then persistenceConfigPath else ""}"
    # This is the master list of ALL paths currently active in the system
    MASTER_JSON="${if masterPersistenceJson != null then masterPersistenceJson else ""}"

    # Formatting/color variables
    red=$(tput setaf 1 || echo "")
    green=$(tput setaf 2 || echo "")
    yellow=$(tput setaf 3 || echo "")
    blue=$(tput setaf 4 || echo "")
    cyan=$(tput setaf 6 || echo "")
    reset=$(tput sgr0 || echo "")
    bold=$(tput bold || echo "")

    DIM='\x1b[2m'
    NC='\x1b[0m'
    MAGENTA='\x1b[0;35m'



    main() {
      if [[ "$#" == '0' ]]; then
        show_help
      fi

      case $1 in
        -h|--help|help)
          show_help
          ;;
        -l|--list|list|ls)
          shift
          list "$@"
          ;;
        -v|--verbose)
          set -x
          shift
          main "$@"
          ;;
        -r|--remove|remove|rm)
          shift
          remove "$@"
          ;;
        -c|--config|config)
          if [[ -f "$PERSIST_JSON_FILE" ]]; then
            cat "$PERSIST_JSON_FILE"
          else
            echo "{}"
          fi
          ;;
        junk)
          shift
          junk "$@"
          ;;
        add)
          shift
          add "$@"
          ;;
        *)
          add "$@"
          ;;
      esac
    }

    show_help() {
      echo -e "''${bold}nyx-persist''${reset} - Manage impermanence paths

''${green}''${bold}Usage:''${reset} nyx-persist [OPTIONS] [COMMAND] [PATH]

''${green}''${bold}Commands:''${reset}
  ''${yellow}list, ls''${reset}       List all persistent files and directories.
  ''${yellow}add [path]''${reset}     Add a path to persistence.
  ''${yellow}remove, rm''${reset}     Remove a path from persistence.
  ''${yellow}junk list''${reset}      List non-persisted items in the storage directory.
  ''${yellow}junk remove''${reset}    Remove non-persisted items from the storage directory.
  ''${yellow}config''${reset}         Show the current local configuration (persist.json).
  ''${yellow}help''${reset}           Show this help message.

''${green}''${bold}Options:''${reset}
  ''${yellow}-v, --verbose''${reset}    Show verbose output.

''${green}''${bold}Examples:''${reset}
  ''${bold}nyx-persist /path/to/dir''${reset}       Add a directory to persistence
  ''${bold}nyx-persist rm /path/to/file''${reset}    Remove a path
  ''${bold}nyx-persist junk list''${reset}           Show orphaned paths in storage
  ''${bold}nyx-persist junk remove''${reset}         Clean up orphaned paths
  "
      exit 0
    }

    # Build a flat list of all absolute paths from persist.json
    # (resolves user-relative paths like "nixos" -> "/home/dx/nixos")
    get_local_paths() {
      local type="$1"  # "directories" or "files"
      if [[ ! -f "$PERSIST_JSON_FILE" ]]; then
        return
      fi
      # Top-level system paths (already absolute)
      jq -r ".''${type}[]?" "$PERSIST_JSON_FILE"
      # User paths (relative to their home dir)
      jq -r ".users // {} | to_entries[] | .key as \$user | .value.''${type}[]? | if startswith(\"/\") then . else (\"~\" + \$user + \"/\" + .) end" "$PERSIST_JSON_FILE" | while IFS= read -r p; do
        if [[ "$p" == "~"* ]]; then
          local username
          username="''${p#\~}"
          username="''${username%%/*}"
          local relpath="''${p#*"/"}"
          local homedir
          homedir=$(eval echo "~$username")
          echo "$homedir/$relpath"
        else
          echo "$p"
        fi
      done
    }

    list() {
      echo -e "''${bold}Persisted Paths (Active System)''${reset}"
      echo -e "''${DIM}Host: $HOSTNAME | Storage: $PERSIST_PATH''${NC}\n"

      if [[ ! -f "$MASTER_JSON" ]]; then
        echo -e "''${red}Error: Master persistence JSON not found.''${reset}"
        return 1
      fi

      local local_dirs
      local_dirs=$(get_local_paths "directories")
      local local_files
      local_files=$(get_local_paths "files")

      echo -e "''${cyan}Directories''${reset}"
      jq -r '.directories[]?' "$MASTER_JSON" | sort | while read -r p; do
        local tag=""
        if ! echo "$local_dirs" | grep -qxF "$p"; then
          tag=" ''${MAGENTA}[module]''${NC}"
        fi
        echo -e "  $green●$reset $p$tag"
      done

      echo -e "\n''${cyan}Files''${reset}"
      jq -r '.files[]?' "$MASTER_JSON" | sort | while read -r p; do
        local tag=""
        if ! echo "$local_files" | grep -qxF "$p"; then
          tag=" ''${MAGENTA}[module]''${NC}"
        fi
        echo -e "  $blue●$reset $p$tag"
      done

      echo -e "\n''${DIM}Legend: ''${green}●''${NC}''${DIM} Directory ''${blue}●''${NC}''${DIM} File ''${MAGENTA}[module]''${NC}''${DIM} Defined in Nix modules''${NC}"
    }

    add() {
      if [[ -z "''${CONFIG_REPO}" ]] || [[ -z "''${PERSIST_JSON_FILE}" ]]; then
         echo -e "''${red}Error: configRepoPath is not set.''${reset}"
         exit 1
      fi

      local dir_only=false
      local path=""

      # Parse flags
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --dir-only)
            dir_only=true
            shift
            ;;
          *)
            path="$1"
            shift
            ;;
        esac
      done

      if [[ -z "$path" ]]; then
        echo -e "''${red}Error: No path specified.''${reset}"
        exit 1
      fi

      # Resolve absolute path
      local abs_path
      abs_path=$(realpath -m "$path")

      # Simple type detection
      local is_dir=true
      if [[ -f "$abs_path" ]]; then is_dir=false; fi

      # Copy to PERSIST_PATH with same permissions
      local dest="''${PERSIST_PATH}''${abs_path}"
      if [[ -e "$abs_path" ]]; then
        echo -e "''${blue}Copying $abs_path → $dest...''${reset}"
        mkdir -p "$(dirname "$dest")"
        cp -a "$abs_path" "$dest"
        echo -e "''${green}Copied to persistent storage.''${reset}"
      else
        echo -e "''${yellow}Warning: $abs_path does not exist on disk, skipping copy.''${reset}"
      fi

      # If --dir-only, stop here — don't touch persist.json
      if [[ "$dir_only" == "true" ]]; then
        echo -e "''${DIM}--dir-only: skipping persist.json update.''${NC}"
        return
      fi

      # Ensure persist.json exists
      if [[ ! -f "$PERSIST_JSON_FILE" ]]; then
        mkdir -p "$(dirname "$PERSIST_JSON_FILE")"
        echo '{"files": [], "directories": []}' > "$PERSIST_JSON_FILE"
      fi

      local tmp_json
      tmp_json=$(mktemp)
      if [[ "$is_dir" == "true" ]]; then
        jq --arg p "$abs_path" '.directories = (.directories + [$p] | unique | sort)' "$PERSIST_JSON_FILE" > "$tmp_json"
      else
        jq --arg p "$abs_path" '.files = (.files + [$p] | unique | sort)' "$PERSIST_JSON_FILE" > "$tmp_json"
      fi
      mv "$tmp_json" "$PERSIST_JSON_FILE"

      echo -e "''${green}Added $abs_path to local persistence.''${reset}"
      echo -e "''${yellow}Note:''${reset} You need to rebuild your system to apply changes."
    }

    remove() {
      if [[ -z "''${PERSIST_JSON_FILE}" ]]; then
         echo -e "''${red}Error: PERSIST_JSON_FILE not set.''${reset}"
         exit 1
      fi

      local path="$1"
      if [[ -z "$path" ]]; then
        # Use fzf if no path given
        if command -v fzf &> /dev/null; then
          path=$(jq -r '.directories[], .files[]' "$PERSIST_JSON_FILE" | fzf --prompt="Select path to remove: ")
        fi
      fi

      if [[ -z "$path" ]]; then
        echo -e "''${red}Error: No path specified.''${reset}"
        exit 1
      fi

      local abs_path
      abs_path=$(realpath -m "$path")

      local tmp_json
      tmp_json=$(mktemp)
      jq --arg p "$abs_path" '
        .directories |= filter(. != $p) |
        .files |= filter(. != $p)
      ' "$PERSIST_JSON_FILE" > "$tmp_json"
      mv "$tmp_json" "$PERSIST_JSON_FILE"

      echo -e "''${yellow}Removed $abs_path from local persistence.''${reset}"

      # Ask whether to also remove from PERSIST_PATH
      local dest="''${PERSIST_PATH}''${abs_path}"
      if [[ -e "$dest" ]]; then
        echo
        read -rp "$(echo -e "''${yellow}Also remove $dest from persistent storage? [y/N]: ''${reset}")" yn
        case "$yn" in
          [Yy]*)
            rm -rf "$dest"
            echo -e "  ''${red}Removed''${reset} $dest"
            ;;
          *)
            echo -e "''${DIM}Leaving $dest in place.''${NC}"
            ;;
        esac
      else
        echo -e "''${DIM}No corresponding path found in $PERSIST_PATH, nothing to clean up.''${NC}"
      fi
    }

    # Get all master persistence paths as absolute paths
    get_master_paths() {
      if [[ ! -f "$MASTER_JSON" ]]; then
        return
      fi
      jq -r '.directories[]?, .files[]?' "$MASTER_JSON" | sort -u
    }

    # Find items in PERSIST_PATH that are NOT in the master persistence list
    junk_list() {
      echo -e "''${bold}Orphaned items in $PERSIST_PATH''${reset}"
      echo -e "''${DIM}These exist in storage but are not in the active persistence config.''${NC}\n"

      local master_paths
      master_paths=$(get_master_paths)

      # Walk top-level entries in persist storage, then check recursively
      local output
      output=$(find "$PERSIST_PATH" -mindepth 1 -maxdepth 1 -not -name '.snapshots' -not -name 'secrets' | sort | while read -r top; do
        local rel_path="''${top#"$PERSIST_PATH"}"
        find_junk_recursive "$top" "$rel_path" "$master_paths"
      done)

      if [[ -n "$output" ]]; then
        echo "$output"
      else
        echo -e "''${green}No orphaned items found.''${reset}"
      fi
    }

    find_junk_recursive() {
      local storage_path="$1"
      local system_path="$2"
      local master_paths="$3"

      # Check if this exact path is persisted
      if echo "$master_paths" | grep -qxF "$system_path"; then
        return  # This path is persisted, skip it and its children
      fi

      # Check if any persisted path is a child of this path
      if echo "$master_paths" | grep -qF "$system_path/"; then
        # Some children are persisted, recurse into subdirectories
        if [[ -d "$storage_path" ]]; then
          find "$storage_path" -mindepth 1 -maxdepth 1 | sort | while read -r child; do
            local child_rel="''${child#"$PERSIST_PATH"}"
            find_junk_recursive "$child" "$child_rel" "$master_paths"
          done
        fi
        return
      fi

      # This path is not persisted and no children are persisted → it's junk
      if [[ -d "$storage_path" ]]; then
        echo -e "  ''${red}●''${reset} $system_path/"
      else
        echo -e "  ''${red}●''${reset} $system_path"
      fi
    }

    junk_remove() {
      echo -e "''${bold}Finding orphaned items in $PERSIST_PATH...''${reset}\n"

      local master_paths
      master_paths=$(get_master_paths)

      local junk_paths
      junk_paths=$(find "$PERSIST_PATH" -mindepth 1 -maxdepth 1 -not -name '.snapshots' -not -name 'secrets' | sort | while read -r top; do
        local rel_path="''${top#"$PERSIST_PATH"}"
        collect_junk "$top" "$rel_path" "$master_paths"
      done)

      if [[ -z "$junk_paths" ]]; then
        echo -e "''${green}No orphaned items found.''${reset}"
        return
      fi

      echo -e "''${red}The following items will be removed:''${reset}"
      echo "$junk_paths" | while IFS= read -r p; do
        echo -e "  ''${red}●''${reset} $p"
      done

      echo
      read -rp "$(echo -e "''${yellow}Remove all orphaned items? [y/N]: ''${reset}")" yn
      case "$yn" in
        [Yy]*)
          echo "$junk_paths" | while IFS= read -r p; do
            local storage_loc="''${PERSIST_PATH}''${p}"
            rm -rf "$storage_loc"
            echo -e "  ''${red}Removed''${reset} $p"
          done
          echo -e "\n''${green}Cleanup complete.''${reset}"
          ;;
        *)
          echo "Aborted."
          ;;
      esac
    }

    collect_junk() {
      local storage_path="$1"
      local system_path="$2"
      local master_paths="$3"

      if echo "$master_paths" | grep -qxF "$system_path"; then
        return
      fi

      if echo "$master_paths" | grep -qF "$system_path/"; then
        if [[ -d "$storage_path" ]]; then
          find "$storage_path" -mindepth 1 -maxdepth 1 | sort | while read -r child; do
            local child_rel="''${child#"$PERSIST_PATH"}"
            collect_junk "$child" "$child_rel" "$master_paths"
          done
        fi
        return
      fi

      echo "$system_path"
    }

    junk() {
      case "''${1:-list}" in
        list|ls)
          junk_list
          ;;
        remove|rm)
          junk_remove
          ;;
        *)
          echo -e "''${red}Unknown junk subcommand: $1''${reset}"
          echo "Usage: nyx-persist junk [list|remove]"
          exit 1
          ;;
      esac
    }

    main "$@"
  '';
}
