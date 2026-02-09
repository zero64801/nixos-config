{
  writeShellApplication,
  lib,
  coreutils,
  util-linux,
  findutils,
  gnugrep,
  gawk,
  gnused,
  rsync,
  jq,
  nix,
  persistentStoragePath ? "/persist/local",
  configRepoPath ? null,
  hostname ? "unknown",
  persistenceConfigPath ? null,
  persistenceJson ? null,
}:

writeShellApplication {
  name = "nyx-persist";

  runtimeInputs = [
    coreutils
    util-linux
    findutils
    gnugrep
    gawk
    gnused
    rsync
    jq
    nix
  ];

  text = ''
        set -euo pipefail

        PERSIST_PATH="${persistentStoragePath}"
        CONFIG_REPO="${if configRepoPath != null then configRepoPath else ""}"
        HOSTNAME="${hostname}"
        PERSIST_CONFIG="${if persistenceConfigPath != null then persistenceConfigPath else ""}"
        PERSIST_JSON="${if persistenceJson != null then persistenceJson else ""}"

        RED='\x1b[0;31m'
        GREEN='\x1b[0;32m'
        YELLOW='\x1b[1;33m'
        BLUE='\x1b[0;34m'
        MAGENTA='\x1b[0;35m'
        CYAN='\x1b[0;36m'
        NC='\x1b[0m'
        BOLD='\x1b[1m'
        DIM='\x1b[2m'

        ICON_INFO='\xe2\x97\x8f'
        ICON_OK='\xe2\x9c\x93'
        ICON_ERR='\xe2\x9c\x97'
        ICON_WAIT='\xe2\x97\x90'
        ICON_EMPTY='\xe2\x97\x8b'

        info() { echo -e "''${BLUE}''${ICON_INFO}''${NC} $1"; }
        success() { echo -e "''${GREEN}''${ICON_OK}''${NC} $1"; }
        warn() { echo -e "''${YELLOW}!''${NC} $1"; }
        error() { echo -e "''${RED}''${ICON_ERR}''${NC} $1" >&2; }
        header() { echo -e "\n''${BOLD}$1''${NC}"; }

        check_config_repo() {
          if [[ -z "''${CONFIG_REPO}" ]] || [[ -z "''${PERSIST_CONFIG}" ]]; then
            error "configRepoPath is not set in nyx.impermanence"
            exit 1
          fi
        }

        ensure_config() {
          check_config_repo
          if [[ ! -f "''${PERSIST_CONFIG}" ]]; then
            mkdir -p "$(dirname "''${PERSIST_CONFIG}")"
            cat > "''${PERSIST_CONFIG}" << 'NIXEOF'
    {
      directories = [ ];
      files = [ ];
      users = { };
    }
    NIXEOF
            success "Created ''${PERSIST_CONFIG}"
          fi
        }

        get_config_json() {
          if [[ -f "''${PERSIST_JSON}" ]]; then
            cat "''${PERSIST_JSON}"
          else
            echo "{}"
          fi
        }

        get_local_config_json() {
           if [[ -f "''${PERSIST_CONFIG}" ]]; then
            if nix-instantiate --eval --strict --json -E "let c = import ''${PERSIST_CONFIG}; in if builtins.isFunction c then c {} else c" 2>/dev/null; then
              return 0
            fi
          fi
          echo "{}"
        }

        read_local_list() {
          local key="$1"
          get_local_config_json | jq -r ".''${key}[]? | if type==\"string\" then . else .directory end"
        }

        read_local_user_list() {
          local user="$1"
          local key="$2"
          get_local_config_json | jq -r ".users[\"''${user}\"].''${key}[]? | if type==\"string\" then . else .directory end"
        }

        detect_user_from_path() {
          local p="$1"
          local abs_path
          abs_path=$(realpath -m "$p")
          if [[ "$abs_path" == /home/* ]]; then
             local u
             u=$(echo "$abs_path" | cut -d/ -f3)
             if id "$u" &>/dev/null; then
                echo "$u"
             fi
          fi
        }

        add_to_list() {
          local key="$1"
          local value="$2"
          local mode="''${3:-}"

          ensure_config

          if read_local_list "''${key}" | grep -qxF "''${value}"; then
            warn "Already in ''${key}: ''${value}"
            return 1
          fi

          local entry
          if [[ -n "''${mode}" ]] && [[ "''${mode}" != "0755" ]]; then
            entry="    { directory = \"''${value}\"; mode = \"''${mode}\"; }"
          else
            entry="    \"''${value}\""
          fi

          awk -v key="''${key}" -v entry="''${entry}" '
            BEGIN { depth = 0; in_list = 0; }
            {
              line = $0; gsub(/[^}{]/, "", line); len = length(line);
              for (i=1; i<=len; i++) { if (substr(line, i, 1) == "{") depth++; if (substr(line, i, 1) == "}") depth--; }
            }
            depth == 1 && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*[[]" { in_list = 1 }
            in_list && /^[[:space:]]*\];/ { print entry; in_list = 0 }
            { print }
          ' "''${PERSIST_CONFIG}" > "''${PERSIST_CONFIG}.tmp" && mv "''${PERSIST_CONFIG}.tmp" "''${PERSIST_CONFIG}"

          return 0
        }

        add_to_user_list() {
          local user="$1"
          local key="$2"
          local value="$3"
          local mode="''${4:-}"

          ensure_config

          if ! grep -q "^[[:space:]]*''${user}[[:space:]]*=" "''${PERSIST_CONFIG}"; then
            sed -i "/^[[:space:]]*users[[:space:]]*=/,/^[[:space:]]*\};/ {
              /^[[:space:]]*\};/ i\\
        ''${user} = {\\
          directories = [ ];\\
          files = [ ];\\
        };
            }" "''${PERSIST_CONFIG}"
          fi

          if read_local_user_list "''${user}" "''${key}" | grep -qxF "''${value}"; then
            warn "Already in ''${user}.''${key}: ''${value}"
            return 1
          fi

          local entry
          if [[ -n "''${mode}" ]] && [[ "''${mode}" != "0755" ]]; then
            entry="        { directory = \"''${value}\"; mode = \"''${mode}\"; }"
          else
            entry="        \"''${value}\""
          fi

          awk -v target_user="''${user}" -v key="''${key}" -v entry="''${entry}" '
            BEGIN { depth = 0; in_users = 0; in_target_user = 0; in_list = 0; }
            {
              line = $0; gsub(/[^}{]/, "", line); len = length(line);

              if (depth == 1 && $0 ~ /^[[:space:]]*users[[:space:]]*=[[:space:]]*[{]/) in_users = 1
              if (in_users && depth == 2 && $0 ~ "^[[:space:]]*" target_user "[[:space:]]*=[[:space:]]*[{]") in_target_user = 1
              if (in_target_user && depth == 3 && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*[[]") in_list = 1

              for (i=1; i<=len; i++) {
                char = substr(line, i, 1)
                if (char == "{") depth++
                if (char == "}") {
                   depth--
                   if (depth < 3) in_target_user = 0
                   if (depth < 2) in_users = 0
                }
              }
            }
            in_list && /^[[:space:]]*\];/ { print entry; in_list = 0 }
            { print }
          ' "''${PERSIST_CONFIG}" > "''${PERSIST_CONFIG}.tmp" && mv "''${PERSIST_CONFIG}.tmp" "''${PERSIST_CONFIG}"

          return 0
        }

        remove_from_list() {
          local key="$1"
          local value="$2"

          if [[ ! -f "''${PERSIST_CONFIG}" ]]; then return 1; fi

          awk -v key="''${key}" -v val="''${value}" '
            BEGIN { depth = 0; in_list = 0; }
            {
              line = $0; gsub(/[^}{]/, "", line); len = length(line);
              for (i=1; i<=len; i++) if (substr(line, i, 1) == "{") depth++;
            }

            depth == 1 && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*[[]" { in_list = 1 }
            in_list && /^[[:space:]]*\];/ { in_list = 0 }

            in_list && (index($0, "\"" val "\"") || index($0, "directory = \"" val "\"")) {
               next
            }

            {
               print
               line = $0; gsub(/[^}{]/, "", line); len = length(line);
               for (i=1; i<=len; i++) if (substr(line, i, 1) == "}") depth--;
            }
          ' "''${PERSIST_CONFIG}" > "''${PERSIST_CONFIG}.tmp" && mv "''${PERSIST_CONFIG}.tmp" "''${PERSIST_CONFIG}"
        }

        remove_from_user_list() {
          local user="$1"
          local key="$2"
          local value="$3"

          if [[ ! -f "''${PERSIST_CONFIG}" ]]; then return 1; fi

          awk -v target_user="''${user}" -v key="''${key}" -v val="''${value}" '
            BEGIN { depth = 0; in_users = 0; in_target_user = 0; in_list = 0; }
            {
               line = $0; gsub(/[^}{]/, "", line); len = length(line);

               if (depth == 1 && $0 ~ /^[[:space:]]*users[[:space:]]*=[[:space:]]*[{]/) in_users = 1
               if (in_users && depth == 2 && $0 ~ "^[[:space:]]*" target_user "[[:space:]]*=[[:space:]]*[{]") in_target_user = 1
               if (in_target_user && depth == 3 && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*[[]") in_list = 1

               for (i=1; i<=len; i++) if (substr(line, i, 1) == "{") depth++;
            }

            in_list && /^[[:space:]]*\];/ { in_list = 0 }

            in_list && (index($0, "\"" val "\"") || index($0, "directory = \"" val "\"")) { next }

            {
               print
               line = $0; gsub(/[^}{]/, "", line); len = length(line);
               for (i=1; i<=len; i++) {
                 if (substr(line, i, 1) == "}") {
                   depth--;
                   if (depth < 3) in_target_user = 0;
                   if (depth < 2) in_users = 0;
                 }
               }
            }
          ' "''${PERSIST_CONFIG}" > "''${PERSIST_CONFIG}.tmp" && mv "''${PERSIST_CONFIG}.tmp" "''${PERSIST_CONFIG}"
        }

        is_active() {
          local path="$1"
          if findmnt --mountpoint "$path" &>/dev/null; then return 0; fi
          if [[ -L "$path" ]]; then
             local target
             target=$(readlink -f "$path")
             if [[ "$target" == "''${PERSIST_PATH}"* ]]; then return 0; fi
          fi
          return 1
        }

        get_size() {
          local path="$1"
          local size
          if [[ -e "''${path}" ]]; then
            if size=$(du -sh "''${path}" 2>/dev/null | cut -f1); then
              echo "''${size}"
            else
              echo "n/a"
            fi
          else
            echo "-"
          fi
        }

        usage() {
          cat << 'EOF'
    nyx-persist - Manage impermanence paths

    USAGE:
        nyx-persist <COMMAND> [OPTIONS]

    COMMANDS:
        list, ls                 List all persisted paths (Source: Active System)
        status, st               Show persistence status
        add <path> [OPTIONS]     Add a path to persistence
        remove, rm <path>        Remove a path from config
        clean, junk              Find and remove files in storage that are not persisted
        check <path>             Check persistence status of a path
        diff                     Show common paths that aren't persisted
        edit                     Open CLI config in $EDITOR
        help                     Show this help

    ADD OPTIONS:
        --user <username>        Add to user's home directory (auto-detected if omitted)
        --mode <mode>            Set directory permissions (default: 0755)
        --type <file|dir>        Force path type
        --no-migrate             Don't copy existing data

    REMOVE OPTIONS:
        --wipe                   Delete data from persistent storage

    EOF
        }

        cmd_list() {
          header "Persisted Paths (Active System)"
          echo -e "''${DIM}Host: ''${HOSTNAME} | Storage: ''${PERSIST_PATH}''${NC}"

          local local_json
          local_json=$(get_local_config_json)

          echo -e "\n''${CYAN}System Directories''${NC}"
          local sys_dirs
          sys_dirs=$(get_config_json | jq -r "to_entries[] | .value.directories[]?")

          local local_sys_dirs
          local_sys_dirs=$(echo "$local_json" | jq -r ".directories[]? | if type==\"string\" then . else .directory end")

          if [[ -n "$sys_dirs" ]]; then
            while IFS= read -r p; do
               local size
               size=$(get_size "''${p}")
               local status="''${YELLOW}''${ICON_WAIT}''${NC}"
               if is_active "''${p}"; then status="''${GREEN}''${ICON_INFO}''${NC}"; fi

               local source_tag=""
               if ! echo "$local_sys_dirs" | grep -qxF "$p"; then
                  source_tag=" ''${MAGENTA}[module]''${NC}"
               fi

               echo -e "  ''${status} ''${p} ''${DIM}(''${size})''${NC}''${source_tag}"
            done <<< "$sys_dirs"
          else
            echo -e "  ''${DIM}(none)''${NC}"
          fi

          echo -e "\n''${CYAN}System Files''${NC}"
          local sys_files
          sys_files=$(get_config_json | jq -r "to_entries[] | .value.files[]?")

          local local_sys_files
          local_sys_files=$(echo "$local_json" | jq -r ".files[]? | if type==\"string\" then . else .file end")

          if [[ -n "$sys_files" ]]; then
            while IFS= read -r p; do
               local status="''${YELLOW}''${ICON_WAIT}''${NC}"
               if is_active "''${p}"; then status="''${GREEN}''${ICON_INFO}''${NC}"; fi

               local source_tag=""
               if ! echo "$local_sys_files" | grep -qxF "$p"; then
                  source_tag=" ''${MAGENTA}[module]''${NC}"
               fi

               echo -e "  ''${status} ''${p} ''${DIM}(file)''${NC}''${source_tag}"
            done <<< "$sys_files"
          else
            echo -e "  ''${DIM}(none)''${NC}"
          fi

          local users
          users=$(get_config_json | jq -r "to_entries[] | .value.users | keys[]?")

          if [[ -n "$users" ]]; then
             echo -e "\n''${CYAN}User Paths''${NC}"
             while IFS= read -r user; do
                echo -e "  ''${BOLD}''${user}''${NC}"

                local u_dirs
                u_dirs=$(get_config_json | jq -r "to_entries[] | .value.users[\"''${user}\"].directories[]?")

                local local_u_dirs
                local_u_dirs=$(echo "$local_json" | jq -r ".users[\"''${user}\"].directories[]? | if type==\"string\" then . else .directory end")

                if [[ -n "$u_dirs" ]]; then
                   while IFS= read -r p; do
                      local size
                      size=$(get_size "''${p}")
                      local status="''${YELLOW}''${ICON_WAIT}''${NC}"
                      if is_active "''${p}"; then status="''${GREEN}''${ICON_INFO}''${NC}"; fi

                      local source_tag=""
                      local home_dir
                      home_dir=$(getent passwd "''${user}" | cut -d: -f6)
                      local rel_path="''${p#"''${home_dir}"/}"

                      if ! echo "$local_u_dirs" | grep -qxF "$rel_path"; then
                         source_tag=" ''${MAGENTA}[module]''${NC}"
                      fi

                      echo -e "    ''${status} ''${p} ''${DIM}(''${size})''${NC}''${source_tag}"
                   done <<< "$u_dirs"
                fi

                local u_files
                u_files=$(get_config_json | jq -r "to_entries[] | .value.users[\"''${user}\"].files[]?")

                local local_u_files
                local_u_files=$(echo "$local_json" | jq -r ".users[\"''${user}\"].files[]? | if type==\"string\" then . else .file end")

                if [[ -n "$u_files" ]]; then
                   while IFS= read -r p; do
                      local status="''${YELLOW}''${ICON_WAIT}''${NC}"
                      if is_active "''${p}"; then status="''${GREEN}''${ICON_INFO}''${NC}"; fi

                      local home_dir
                      home_dir=$(getent passwd "''${user}" | cut -d: -f6)
                      local rel_path="''${p#"''${home_dir}"/}"

                      local source_tag=""
                      if ! echo "$local_u_files" | grep -qxF "$rel_path"; then
                         source_tag=" ''${MAGENTA}[module]''${NC}"
                      fi

                      echo -e "    ''${status} ''${p} ''${DIM}(file)''${NC}''${source_tag}"
                   done <<< "$u_files"
                fi
             done <<< "$users"
          fi

          echo ""
          echo -e "''${DIM}Legend: ''${GREEN}''${ICON_INFO}''${NC}''${DIM}=mounted/active ''${MAGENTA}[module]''${NC}''${DIM}=from other nix modules''${NC}"
        }

        cmd_clean() {
          header "Cleaning Junk Files"
          info "Scanning ''${PERSIST_PATH} for unmanaged files..."

          if [[ ! -d "''${PERSIST_PATH}" ]]; then
             error "Persistence path not found."
             exit 1
          fi

          local valid_prefixes_file
          valid_prefixes_file=$(mktemp)
          get_config_json | jq -r '
            to_entries[] | .key as $storage | .value as $root |
            ($root.directories[]? | $storage + .),
            ($root.users[]? | .directories[]? | $storage + .)
          ' > "$valid_prefixes_file"

          local valid_exact_file
          valid_exact_file=$(mktemp)
          get_config_json | jq -r '
            to_entries[] | .key as $storage | .value as $root |
            ($root.files[]? | $storage + .),
            ($root.users[]? | .files[]? | $storage + .)
          ' > "$valid_exact_file"

          local all_explicit
          all_explicit=$(cat "$valid_prefixes_file" "$valid_exact_file")

          echo "''${PERSIST_PATH}" >> "$valid_exact_file"

          while IFS= read -r p; do
             if [[ -n "$p" ]]; then
                local parent="$p"
                while [[ "$parent" != "''${PERSIST_PATH}" ]] && [[ "$parent" != "/" ]] && [[ "$parent" != "." ]]; do
                   parent=$(dirname "$parent")
                   echo "$parent" >> "$valid_exact_file"
                done
             fi
          done <<< "$all_explicit"

          local junk_list
          junk_list=$(find "''${PERSIST_PATH}" -mindepth 1 | awk \
            -v prefixes_file="$valid_prefixes_file" \
            -v exact_file="$valid_exact_file" \
            -v root="''${PERSIST_PATH}" '
            BEGIN {
              while ((getline line < prefixes_file) > 0) {
                if (line != "") prefixes[line] = 1
              }
              close(prefixes_file)

              while ((getline line < exact_file) > 0) {
                if (line != "") exact[line] = 1
              }
              close(exact_file)
            }
            {
              path = $0

              if (index(path, root "/secrets") == 1) next

              if (path in exact) next

              is_valid_child = 0
              for (prefix in prefixes) {
                if (index(path, prefix "/") == 1) {
                  is_valid_child = 1
                  break
                }
                if (path == prefix) {
                  is_valid_child = 1
                  break
                }
              }

              if (is_valid_child) next

              print path
            }
          ')

          rm "$valid_prefixes_file" "$valid_exact_file"

          if [[ -z "$junk_list" ]]; then
             success "No junk files found. Storage is clean."
             return 0
          fi

          echo -e "\n''${YELLOW}The following files/directories are in storage but NOT persisted:''${NC}"

          while IFS= read -r line; do
             printf "  %b %s%b\n" "''${RED}''${ICON_ERR}" "$line" "''${NC}"
          done <<< "$junk_list"

          echo -e "\n''${BOLD}WARNING: This will permanently delete these files!''${NC}"
          read -r -p "Do you want to delete them? [y/N] " response
          if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
             echo "$junk_list" | while read -r junk; do
                if [[ -e "$junk" ]]; then
                   echo -e "Deleting: $junk"
                   sudo rm -rf "$junk"
                fi
             done
             success "Cleanup complete."
          else
             info "Aborted."
          fi
        }

        cmd_status() {
          header "Impermanence Status"
          echo -e "\n''${CYAN}System''${NC}"
          echo -e "  Host: ''${HOSTNAME}"
          echo -e "  Storage: ''${PERSIST_PATH}"
          if [[ -n "''${PERSIST_CONFIG}" ]]; then echo -e "  Config: ''${PERSIST_CONFIG}"; fi
          echo -e "  Source: ''${GREEN}Active System (Evaluated JSON)''${NC}"

          if [[ -d "''${PERSIST_PATH}" ]]; then
            local total_size available used_percent
            if ! total_size=$(du -sh "''${PERSIST_PATH}" 2>/dev/null | cut -f1); then total_size="n/a"; fi
            if ! available=$(df -h "''${PERSIST_PATH}" 2>/dev/null | awk 'NR==2 {print $4}'); then available="-"; fi
            if ! used_percent=$(df -h "''${PERSIST_PATH}" 2>/dev/null | awk 'NR==2 {print $5}'); then used_percent="-"; fi
            echo -e "  Persisted: ''${total_size}"
            echo -e "  Available: ''${available} (''${used_percent} full)"
          else
            error "Storage path does not exist!"
          fi
        }

        cmd_add() {
          local path=""
          local user=""
          local mode="0755"
          local force_type=""
          local migrate=true

          while [[ $# -gt 0 ]]; do
            case "$1" in
              --user) user="$2"; shift 2 ;;
              --mode) mode="$2"; shift 2 ;;
              --type) force_type="$2"; shift 2 ;;
              --no-migrate) migrate=false; shift ;;
              -*) error "Unknown option: $1"; exit 1 ;;
              *) path="$1"; shift ;;
            esac
          done

          if [[ -z "''${path}" ]]; then error "No path specified"; usage; exit 1; fi
          check_config_repo

          local full_path="''${path}"
          local config_path="''${path}"

          if [[ -z "''${user}" ]]; then
             user=$(detect_user_from_path "''${path}")
             if [[ -n "''${user}" ]]; then
                info "Detected user path: ''${user}"
             fi
          fi

          if [[ -n "''${user}" ]]; then
            local home_dir
            home_dir=$(getent passwd "''${user}" | cut -d: -f6)
            if [[ -z "''${home_dir}" ]]; then error "User ''${user} not found"; exit 1; fi

            if [[ "''${path}" != /* ]]; then
              full_path="''${home_dir}/''${path}"
              config_path="''${path}"
            else
              if [[ "''${path}" == "''${home_dir}"* ]]; then
                 full_path="''${path}"
                 config_path="''${path#"''${home_dir}"/}"
              else
                 warn "Path ''${path} is not inside ''${home_dir}, but --user was set."
                 full_path="''${path}"
                 config_path="''${path}"
              fi
            fi
          fi

          full_path=$(realpath -m "''${full_path}")

          if is_active "''${full_path}"; then
             info "Path is currently active (mounted/linked)."
          fi

          local path_type
          if [[ -n "''${force_type}" ]]; then path_type="''${force_type}"
          elif [[ -f "''${full_path}" ]]; then path_type="file"
          elif [[ -d "''${full_path}" ]]; then path_type="dir"
          elif [[ "''${full_path}" == *.* ]] && [[ ! "$(basename "''${full_path}")" == .* ]]; then path_type="file"
          else path_type="dir"
          fi

          local persist_target="''${PERSIST_PATH}''${full_path}"
          info "Adding: ''${full_path} (type: ''${path_type})"

          if [[ "''${migrate}" == true ]] && [[ -e "''${full_path}" ]] && [[ ! -e "''${persist_target}" ]]; then
            info "Migrating existing data..."
            if [[ ! -d "''${PERSIST_PATH}" ]]; then sudo mkdir -p "''${PERSIST_PATH}"; fi
            if [[ "''${path_type}" == "dir" ]]; then
               sudo rsync -aR "''${full_path}/" "''${PERSIST_PATH}/"
            else
               sudo rsync -aR "''${full_path}" "''${PERSIST_PATH}/"
            fi
            success "Data migrated to persistent storage"
          elif [[ ! -e "''${persist_target}" ]]; then
            info "Creating in persistent storage..."
            if [[ "''${path_type}" == "dir" ]]; then
              sudo mkdir -p "''${persist_target}"
              sudo chmod "''${mode}" "''${persist_target}"
              if [[ -n "''${user}" ]]; then sudo chown "''${user}:$(id -gn "''${user}")" "''${persist_target}"; fi
            else
              sudo mkdir -p "$(dirname "''${persist_target}")"
              sudo touch "''${persist_target}"
              if [[ -n "''${user}" ]]; then sudo chown "''${user}:$(id -gn "''${user}")" "''${persist_target}"; fi
            fi
          fi

          if [[ -n "''${user}" ]]; then
            if [[ "''${path_type}" == "dir" ]]; then add_to_user_list "''${user}" "directories" "''${config_path}" "''${mode}"
            else add_to_user_list "''${user}" "files" "''${config_path}"; fi
          else
            if [[ "''${path_type}" == "dir" ]]; then add_to_list "directories" "''${config_path}" "''${mode}"
            else add_to_list "files" "''${config_path}"; fi
          fi

          success "Added to config: ''${PERSIST_CONFIG}"
          echo ""
          info "Run 'sudo nixos-rebuild switch' to apply"
        }

        cmd_remove() {
          local path=""
          local user=""
          local wipe=false

          while [[ $# -gt 0 ]]; do
            case "$1" in
              --user) user="$2"; shift 2 ;;
              --wipe) wipe=true; shift ;;
              -*) error "Unknown option: $1"; exit 1 ;;
              *) path="$1"; shift ;;
            esac
          done

          if [[ -z "''${path}" ]]; then error "No path specified"; exit 1; fi
          check_config_repo

          if [[ -z "''${user}" ]]; then
             user=$(detect_user_from_path "''${path}")
             if [[ -n "''${user}" ]]; then
                info "Detected user path: ''${user}"
             fi
          fi

          if [[ -n "''${user}" ]]; then
            remove_from_user_list "''${user}" "directories" "''${path}"
            remove_from_user_list "''${user}" "files" "''${path}"
          else
            remove_from_list "directories" "''${path}"
            remove_from_list "files" "''${path}"
          fi

          success "Removed from config: ''${path}"

          if [[ "''${wipe}" == "true" ]]; then
             local full_path="''${path}"
             if [[ -n "''${user}" ]]; then
                local home_dir
                home_dir=$(getent passwd "''${user}" | cut -d: -f6)
                if [[ "''${path}" != /* ]]; then full_path="''${home_dir}/''${path}"; fi
             fi

             local persist_target="''${PERSIST_PATH}''${full_path}"
             if [[ -e "''${persist_target}" ]]; then
                info "Wiping data from ''${persist_target}..."
                sudo rm -rf "''${persist_target}"
                success "Data wiped."
             else
                warn "Data not found at ''${persist_target}"
             fi
          else
             warn "Data remains in ''${PERSIST_PATH} - use --wipe to delete"
          fi

          info "Run 'sudo nixos-rebuild switch' to apply"
        }

        cmd_check() {
          local path="$1"
          if [[ -z "''${path}" ]]; then error "No path specified"; exit 1; fi
          local full_path
          full_path=$(realpath -m "''${path}")
          local persist_target="''${PERSIST_PATH}''${full_path}"

          header "Path: ''${full_path}"
          echo -e "\n''${CYAN}Status''${NC}"
          if is_active "''${full_path}"; then success "Currently mounted/active"; else warn "NOT mounted"; fi
          if [[ -e "''${persist_target}" ]]; then
            local size
            size=$(get_size "''${persist_target}")
            success "Exists in storage (''${size})"
          else warn "NOT in persistent storage"; fi

          local in_json
          in_json=$(get_config_json | jq -r "
            to_entries[] | .key as \$storage | .value as \$root |
            (\$root.files[]? | \$storage + .),
            (\$root.directories[]? | \$storage + .),
            (\$root.users[]? | (.files[]? | \$storage + .), (.directories[]? | \$storage + .))
          " | grep -xF "''${persist_target}" || true)

          if [[ -n "''${in_json}" ]]; then success "In System Config (Active)"; else info "Not in active config"; fi
        }

        cmd_diff() {
          header "Persistence Recommendations"
          local common_paths=(
            "/var/log:dir:Logs"
            "/var/lib/nixos:dir:NixOS state (UIDs/GIDs)"
            "/var/lib/systemd/coredump:dir:Core dumps"
            "/var/lib/bluetooth:dir:Bluetooth pairings"
            "/var/lib/NetworkManager:dir:Network state"
            "/etc/NetworkManager/system-connections:dir:WiFi passwords"
            "/etc/machine-id:file:Machine identity"
            "/etc/adjtime:file:Hardware clock"
            "/etc/ssh/ssh_host_ed25519_key:file:SSH host key"
            "/etc/ssh/ssh_host_rsa_key:file:SSH host key (RSA)"
          )
          echo -e "\n''${CYAN}Common System Paths''${NC}"
          for entry in "''${common_paths[@]}"; do
            IFS=: read -r p _ desc <<< "''${entry}"
            if [[ -e "''${p}" ]]; then
              if is_active "''${p}"; then echo -e "  ''${GREEN}''${ICON_INFO}''${NC} ''${p} ''${DIM}- ''${desc}''${NC}"; else echo -e "  ''${RED}''${ICON_EMPTY}''${NC} ''${p} ''${DIM}- ''${desc}''${NC}"; fi
            fi
          done
          echo ""
          echo -e "''${DIM}Legend: ''${GREEN}''${ICON_INFO}''${NC}''${DIM}=persisted ''${RED}''${ICON_EMPTY}''${NC}''${DIM}=NOT persisted''${NC}"
          echo -e "\n''${DIM}Add missing paths with: nyx-persist add <path>''${NC}"
        }

        cmd_edit() {
          check_config_repo
          ensure_config
          ''${EDITOR:-nano} "''${PERSIST_CONFIG}"
        }

        main() {
          if [[ $# -eq 0 ]]; then usage; exit 0; fi
          local cmd="$1"; shift
          case "''${cmd}" in
            list|ls) cmd_list ;;
            status|st) cmd_status ;;
            add|a) cmd_add "$@" ;;
            remove|rm) cmd_remove "$@" ;;
            clean|junk) cmd_clean ;;
            check|c) cmd_check "$@" ;;
            diff|d) cmd_diff ;;
            edit|e) cmd_edit ;;
            help|h|--help|-h) usage ;;
            *) error "Unknown command: ''${cmd}"; usage; exit 1 ;;
          esac
        }

        main "$@"
  '';
}
