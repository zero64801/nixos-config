{ writeShellApplication
, lib
, coreutils
, util-linux
, findutils
, gnugrep
, gawk
, gnused
, rsync
, persistentStoragePath ? "/persist/local"
, configRepoPath ? null
, hostname ? "unknown"
, persistenceConfigPath ? null
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
  ];

  text = ''
    set -euo pipefail

    PERSIST_PATH="${persistentStoragePath}"
    CONFIG_REPO="${if configRepoPath != null then configRepoPath else ""}"
    HOSTNAME="${hostname}"
    PERSIST_CONFIG="${if persistenceConfigPath != null then persistenceConfigPath else ""}"

    # Colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    BOLD='\033[1m'
    DIM='\033[2m'

    # Print helpers
    info() { echo -e "''${BLUE}●''${NC} $1"; }
    success() { echo -e "''${GREEN}✓''${NC} $1"; }
    warn() { echo -e "''${YELLOW}!''${NC} $1"; }
    error() { echo -e "''${RED}✗''${NC} $1" >&2; }
    header() { echo -e "\n''${BOLD}$1''${NC}"; }

    # Check if config repo is set
    check_config_repo() {
      if [[ -z "$CONFIG_REPO" ]] || [[ -z "$PERSIST_CONFIG" ]]; then
        error "configRepoPath is not set in nyx.impermanence"
        echo "Set it in your NixOS config to enable persistence management:"
        echo ""
        echo "  nyx.impermanence.configRepoPath = \"/home/user/nixos\";"
        echo ""
        exit 1
      fi
    }

    # Ensure config file exists with empty structure
    ensure_config() {
      check_config_repo
      if [[ ! -f "$PERSIST_CONFIG" ]]; then
        mkdir -p "$(dirname "$PERSIST_CONFIG")"
        cat > "$PERSIST_CONFIG" << 'NIXEOF'
# Persistence configuration for this host
# Managed by nyx-persist CLI - you can also edit manually
{
  directories = [
  ];
  files = [
  ];
  users = {
  };
}
NIXEOF
        success "Created $PERSIST_CONFIG"
      fi
    }

    # Read a list from the Nix config (simple parsing for our known format)
    read_list() {
      local key="$1"
      if [[ ! -f "$PERSIST_CONFIG" ]]; then
        return
      fi
      # Extract items between key = [ and ];
      sed -n "/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\[/,/^[[:space:]]*\];/p" "$PERSIST_CONFIG" | \
        grep -E '^\s+"' | \
        sed 's/^[[:space:]]*"\(.*\)".*$/\1/'
    }

    # Read user directories/files
    read_user_list() {
      local user="$1"
      local key="$2"
      if [[ ! -f "$PERSIST_CONFIG" ]]; then
        return
      fi
      # Find user block and extract the list
      awk -v user="$user" -v key="$key" '
        $0 ~ "^[[:space:]]*" user "[[:space:]]*=" { in_user=1 }
        in_user && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { in_list=1; next }
        in_list && /\];/ { in_list=0 }
        in_list && /^[[:space:]]*"/ {
          gsub(/^[[:space:]]*"|".*$/, "")
          print
        }
        in_user && /^[[:space:]]*\};/ { in_user=0 }
      ' "$PERSIST_CONFIG"
    }

    # Get list of users in config
    read_users() {
      if [[ ! -f "$PERSIST_CONFIG" ]]; then
        return
      fi
      awk '
        /^[[:space:]]*users[[:space:]]*=/ { in_users=1; next }
        in_users && /^[[:space:]]*\};/ { exit }
        in_users && /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*=/ {
          gsub(/^[[:space:]]*|[[:space:]]*=.*$/, "")
          print
        }
      ' "$PERSIST_CONFIG"
    }

    # Add item to a list in the Nix config
    add_to_list() {
      local key="$1"
      local value="$2"
      local mode="''${3:-}"

      ensure_config

      # Check if already exists
      if read_list "$key" | grep -qxF "$value"; then
        warn "Already in $key: $value"
        return 1
      fi

      local entry
      if [[ -n "$mode" ]] && [[ "$mode" != "0755" ]]; then
        entry="    { directory = \"$value\"; mode = \"$mode\"; }"
      else
        entry="    \"$value\""
      fi

      # Insert before the closing ];
      sed -i "/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\[/,/^[[:space:]]*\];/ {
        /^[[:space:]]*\];/ i\\
$entry
      }" "$PERSIST_CONFIG"

      return 0
    }

    # Add item to user's list
    add_to_user_list() {
      local user="$1"
      local key="$2"
      local value="$3"
      local mode="''${4:-}"

      ensure_config

      # Check if user block exists, create if not
      if ! grep -q "^[[:space:]]*$user[[:space:]]*=" "$PERSIST_CONFIG"; then
        # Add user block before closing }; of users
        sed -i "/^[[:space:]]*users[[:space:]]*=/,/^[[:space:]]*\};/ {
          /^[[:space:]]*\};/ i\\
    $user = {\\
      directories = [\\
      ];\\
      files = [\\
      ];\\
    };
        }" "$PERSIST_CONFIG"
      fi

      # Check if already exists
      if read_user_list "$user" "$key" | grep -qxF "$value"; then
        warn "Already in $user.$key: $value"
        return 1
      fi

      local entry
      if [[ -n "$mode" ]] && [[ "$mode" != "0755" ]]; then
        entry="        { directory = \"$value\"; mode = \"$mode\"; }"
      else
        entry="        \"$value\""
      fi

      # Find user block and insert into the right list
      awk -v user="$user" -v key="$key" -v entry="$entry" '
        $0 ~ "^[[:space:]]*" user "[[:space:]]*=" { in_user=1 }
        in_user && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { in_list=1 }
        in_list && /\];/ {
          print entry
          in_list=0
        }
        { print }
        in_user && /^[[:space:]]*\};/ { in_user=0 }
      ' "$PERSIST_CONFIG" > "$PERSIST_CONFIG.tmp" && mv "$PERSIST_CONFIG.tmp" "$PERSIST_CONFIG"

      return 0
    }

    # Remove item from list
    remove_from_list() {
      local key="$1"
      local value="$2"

      if [[ ! -f "$PERSIST_CONFIG" ]]; then
        return 1
      fi

      # Remove line matching the value (both string and attrset forms)
      local escaped_value
      escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$()+?{|]/\\&/g')

      sed -i "/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\[/,/^[[:space:]]*\];/ {
        /\"$escaped_value\"/d
        /directory[[:space:]]*=[[:space:]]*\"$escaped_value\"/d
      }" "$PERSIST_CONFIG"
    }

    # Remove item from user list
    remove_from_user_list() {
      local user="$1"
      local key="$2"
      local value="$3"

      if [[ ! -f "$PERSIST_CONFIG" ]]; then
        return 1
      fi

      local escaped_value
      escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$()+?{|]/\\&/g')

      awk -v user="$user" -v key="$key" -v value="$escaped_value" '
        $0 ~ "^[[:space:]]*" user "[[:space:]]*=" { in_user=1 }
        in_user && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { in_list=1 }
        in_list && /\];/ { in_list=0 }
        in_list && ($0 ~ "\"" value "\"" || $0 ~ "directory[[:space:]]*=[[:space:]]*\"" value "\"") { next }
        { print }
        in_user && /^[[:space:]]*\};/ { in_user=0 }
      ' "$PERSIST_CONFIG" > "$PERSIST_CONFIG.tmp" && mv "$PERSIST_CONFIG.tmp" "$PERSIST_CONFIG"
    }

    # Check if path is a bind mount
    is_bind_mounted() {
      local path="$1"
      findmnt --type none --options bind --target "$path" &>/dev/null
    }

    # Get bind-mounted paths
    get_mounted_paths() {
      findmnt --type none --options bind --noheadings --output TARGET 2>/dev/null | sort -u || true
    }

    # Get size of path
    get_size() {
      local path="$1"
      if [[ -e "$path" ]]; then
        du -sh "$path" 2>/dev/null | cut -f1
      else
        echo "-"
      fi
    }

    # Print usage
    usage() {
      cat << 'EOF'
nyx-persist - Manage impermanence paths

USAGE:
    nyx-persist <COMMAND> [OPTIONS]

COMMANDS:
    list, ls                 List all persisted paths
    status, st               Show persistence status and health checks
    add <path> [OPTIONS]     Add a path to persistence
    remove, rm <path>        Remove a path from config
    check <path>             Check persistence status of a path
    diff                     Show common paths that aren't persisted
    edit                     Open CLI config in $EDITOR
    help                     Show this help

ADD OPTIONS:
    --user <name>            Add to user's home directory persistence
    --mode <mode>            Set permissions (default: 0755 for dirs)
    --type <file|dir>        Force type (auto-detected by default)
    --no-migrate             Don't migrate existing data

EXAMPLES:
    nyx-persist add /var/lib/myapp
    nyx-persist add .config/app --user dx --mode 0700
    nyx-persist add /etc/myfile --type file
    nyx-persist remove /var/lib/myapp
    nyx-persist remove .config/app --user dx
    nyx-persist list

NOTES:
    - All paths stored in hosts/<hostname>/persistence.nix
    - Run 'nixos-rebuild switch' after changes to apply
    - Data is automatically migrated when adding paths
EOF
    }

    # List all persisted paths
    cmd_list() {
      header "Persisted Paths"
      echo -e "''${DIM}Host: $HOSTNAME | Storage: $PERSIST_PATH''${NC}"

      if [[ -n "$PERSIST_CONFIG" ]] && [[ -f "$PERSIST_CONFIG" ]]; then
        echo -e "''${DIM}Config: $PERSIST_CONFIG''${NC}"
      fi

      # System directories
      echo -e "\n''${CYAN}System Directories''${NC}"
      local has_dirs=false

      # From CLI config
      while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
          local size
          size=$(get_size "$dir")
          local status="''${YELLOW}◐''${NC}"
          if is_bind_mounted "$dir"; then
            status="''${GREEN}●''${NC}"
          fi
          echo -e "  $status $dir ''${DIM}($size) [cli]''${NC}"
          has_dirs=true
        fi
      done < <(read_list "directories")

      # Show mounted dirs not in CLI config (from NixOS config)
      while IFS= read -r mount; do
        if [[ -n "$mount" && -d "$mount" ]]; then
          local in_cli
          in_cli=$(read_list "directories" | grep -xF "$mount" || true)
          if [[ -z "$in_cli" ]]; then
            local size
            size=$(get_size "$mount")
            echo -e "  ''${GREEN}●''${NC} $mount ''${DIM}($size) [nixos]''${NC}"
            has_dirs=true
          fi
        fi
      done < <(get_mounted_paths)

      if [[ "$has_dirs" == "false" ]]; then
        echo -e "  ''${DIM}(none)''${NC}"
      fi

      # System files
      echo -e "\n''${CYAN}System Files''${NC}"
      local has_files=false

      while IFS= read -r file; do
        if [[ -n "$file" ]]; then
          local status="''${YELLOW}◐''${NC}"
          if is_bind_mounted "$file"; then
            status="''${GREEN}●''${NC}"
          fi
          echo -e "  $status $file ''${DIM}[cli]''${NC}"
          has_files=true
        fi
      done < <(read_list "files")

      while IFS= read -r mount; do
        if [[ -n "$mount" && -f "$mount" ]]; then
          local in_cli
          in_cli=$(read_list "files" | grep -xF "$mount" || true)
          if [[ -z "$in_cli" ]]; then
            echo -e "  ''${GREEN}●''${NC} $mount ''${DIM}[nixos]''${NC}"
            has_files=true
          fi
        fi
      done < <(get_mounted_paths)

      if [[ "$has_files" == "false" ]]; then
        echo -e "  ''${DIM}(none)''${NC}"
      fi

      # User paths
      local users
      users=$(read_users)
      if [[ -n "$users" ]]; then
        echo -e "\n''${CYAN}User Paths''${NC}"
        while IFS= read -r user; do
          if [[ -n "$user" ]]; then
            echo -e "  ''${BOLD}$user''${NC}"
            local home_dir
            home_dir=$(getent passwd "$user" | cut -d: -f6 || echo "/home/$user")

            # User directories
            while IFS= read -r dir; do
              if [[ -n "$dir" ]]; then
                local full_path="$home_dir/$dir"
                local size
                size=$(get_size "$full_path")
                local status="''${YELLOW}◐''${NC}"
                if is_bind_mounted "$full_path"; then
                  status="''${GREEN}●''${NC}"
                fi
                echo -e "    $status $dir ''${DIM}($size)''${NC}"
              fi
            done < <(read_user_list "$user" "directories")

            # User files
            while IFS= read -r file; do
              if [[ -n "$file" ]]; then
                local full_path="$home_dir/$file"
                local status="''${YELLOW}◐''${NC}"
                if is_bind_mounted "$full_path"; then
                  status="''${GREEN}●''${NC}"
                fi
                echo -e "    $status $file ''${DIM}(file)''${NC}"
              fi
            done < <(read_user_list "$user" "files")
          fi
        done <<< "$users"
      fi

      echo ""
      echo -e "''${DIM}Legend: ''${GREEN}●''${NC}''${DIM}=mounted ''${YELLOW}◐''${NC}''${DIM}=pending rebuild''${NC}"
    }

    # Show status
    cmd_status() {
      header "Impermanence Status"

      echo -e "\n''${CYAN}System''${NC}"
      echo -e "  Host: $HOSTNAME"
      echo -e "  Storage: $PERSIST_PATH"
      if [[ -n "$PERSIST_CONFIG" ]]; then
        echo -e "  Config: $PERSIST_CONFIG"
      fi

      if [[ -d "$PERSIST_PATH" ]]; then
        local total_size available used_percent
        total_size=$(du -sh "$PERSIST_PATH" 2>/dev/null | cut -f1)
        available=$(df -h "$PERSIST_PATH" 2>/dev/null | awk 'NR==2 {print $4}')
        used_percent=$(df -h "$PERSIST_PATH" 2>/dev/null | awk 'NR==2 {print $5}')
        echo -e "  Persisted: $total_size"
        echo -e "  Available: $available ($used_percent full)"
      else
        error "Storage path does not exist!"
      fi

      header "Health Checks"

      if is_bind_mounted "/etc/machine-id"; then
        success "/etc/machine-id persisted"
      else
        warn "/etc/machine-id NOT persisted - changes on reboot"
      fi

      if is_bind_mounted "/var/lib/nixos"; then
        success "/var/lib/nixos persisted - UIDs/GIDs stable"
      else
        warn "/var/lib/nixos NOT persisted - UIDs/GIDs may change"
      fi

      if is_bind_mounted "/var/log"; then
        success "/var/log persisted"
      else
        warn "/var/log NOT persisted - logs lost on reboot"
      fi

      header "Statistics"
      local mount_count
      mount_count=$(get_mounted_paths | wc -l)
      echo -e "  Active mounts: $mount_count"
    }

    # Add path to persistence
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

      if [[ -z "$path" ]]; then
        error "No path specified"
        usage
        exit 1
      fi

      check_config_repo

      # Resolve full path
      local full_path="$path"
      local config_path="$path"

      if [[ -n "$user" ]]; then
        local home_dir
        home_dir=$(getent passwd "$user" | cut -d: -f6)
        if [[ -z "$home_dir" ]]; then
          error "User '$user' not found"
          exit 1
        fi
        if [[ "$path" != /* ]]; then
          full_path="$home_dir/$path"
          config_path="$path"
        else
          config_path="''${path#$home_dir/}"
        fi
      fi

      full_path=$(realpath -m "$full_path")

      # Check if already mounted
      if is_bind_mounted "$full_path"; then
        warn "Already persisted: $full_path"
        exit 0
      fi

      # Detect type
      local path_type
      if [[ -n "$force_type" ]]; then
        path_type="$force_type"
      elif [[ -f "$full_path" ]]; then
        path_type="file"
      elif [[ -d "$full_path" ]]; then
        path_type="dir"
      elif [[ "$full_path" == *.* ]] && [[ ! "$(basename "$full_path")" == .* ]]; then
        path_type="file"
      else
        path_type="dir"
      fi

      local persist_target="$PERSIST_PATH$full_path"

      info "Adding: $full_path (type: $path_type)"

      # Migrate data
      if [[ "$migrate" == true ]] && [[ -e "$full_path" ]] && [[ ! -e "$persist_target" ]]; then
        info "Migrating existing data..."
        sudo mkdir -p "$(dirname "$persist_target")"

        if [[ "$path_type" == "dir" ]]; then
          sudo rsync -a "$full_path/" "$persist_target/"
        else
          sudo cp -a "$full_path" "$persist_target"
        fi
        success "Data migrated to persistent storage"
      elif [[ ! -e "$persist_target" ]]; then
        info "Creating in persistent storage..."
        if [[ "$path_type" == "dir" ]]; then
          sudo mkdir -p "$persist_target"
          sudo chmod "$mode" "$persist_target"
          if [[ -n "$user" ]]; then
            sudo chown "$user:$(id -gn "$user")" "$persist_target"
          fi
        else
          sudo mkdir -p "$(dirname "$persist_target")"
          sudo touch "$persist_target"
          if [[ -n "$user" ]]; then
            sudo chown "$user:$(id -gn "$user")" "$persist_target"
          fi
        fi
      fi

      # Update Nix config
      if [[ -n "$user" ]]; then
        if [[ "$path_type" == "dir" ]]; then
          add_to_user_list "$user" "directories" "$config_path" "$mode"
        else
          add_to_user_list "$user" "files" "$config_path"
        fi
      else
        if [[ "$path_type" == "dir" ]]; then
          add_to_list "directories" "$config_path" "$mode"
        else
          add_to_list "files" "$config_path"
        fi
      fi

      success "Added to config: $PERSIST_CONFIG"
      echo ""
      info "Run 'sudo nixos-rebuild switch' to apply"
    }

    # Remove path
    cmd_remove() {
      local path=""
      local user=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --user) user="$2"; shift 2 ;;
          -*) error "Unknown option: $1"; exit 1 ;;
          *) path="$1"; shift ;;
        esac
      done

      if [[ -z "$path" ]]; then
        error "No path specified"
        exit 1
      fi

      check_config_repo

      if [[ -n "$user" ]]; then
        remove_from_user_list "$user" "directories" "$path"
        remove_from_user_list "$user" "files" "$path"
      else
        remove_from_list "directories" "$path"
        remove_from_list "files" "$path"
      fi

      success "Removed from config: $path"
      warn "Data remains in $PERSIST_PATH - delete manually if needed"
      info "Run 'sudo nixos-rebuild switch' to apply"
    }

    # Check a path
    cmd_check() {
      local path="$1"

      if [[ -z "$path" ]]; then
        error "No path specified"
        exit 1
      fi

      local full_path
      full_path=$(realpath -m "$path")
      local persist_target="$PERSIST_PATH$full_path"

      header "Path: $full_path"

      echo -e "\n''${CYAN}Status''${NC}"
      if is_bind_mounted "$full_path"; then
        success "Currently mounted"
      else
        warn "NOT mounted"
      fi

      if [[ -e "$persist_target" ]]; then
        local size
        size=$(get_size "$persist_target")
        success "Exists in storage ($size)"
      else
        warn "NOT in persistent storage"
      fi

      # Check if in CLI config
      local in_dirs in_files
      in_dirs=$(read_list "directories" | grep -xF "$full_path" || true)
      in_files=$(read_list "files" | grep -xF "$full_path" || true)

      if [[ -n "$in_dirs" ]] || [[ -n "$in_files" ]]; then
        success "In CLI config"
      else
        info "Not in CLI config (may be in NixOS config)"
      fi
    }

    # Show diff of common paths
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
        IFS=: read -r p t desc <<< "$entry"
        if [[ -e "$p" ]]; then
          if is_bind_mounted "$p"; then
            echo -e "  ''${GREEN}●''${NC} $p ''${DIM}- $desc''${NC}"
          else
            echo -e "  ''${RED}○''${NC} $p ''${DIM}- $desc''${NC}"
          fi
        fi
      done

      echo ""
      echo -e "''${DIM}Legend: ''${GREEN}●''${NC}''${DIM}=persisted ''${RED}○''${NC}''${DIM}=NOT persisted''${NC}"
      echo -e "\n''${DIM}Add missing paths with: nyx-persist add <path>''${NC}"
    }

    # Edit config file
    cmd_edit() {
      check_config_repo
      ensure_config
      ''${EDITOR:-nano} "$PERSIST_CONFIG"
    }

    # Main
    main() {
      if [[ $# -eq 0 ]]; then
        usage
        exit 0
      fi

      local cmd="$1"
      shift

      case "$cmd" in
        list|ls) cmd_list ;;
        status|st) cmd_status ;;
        add|a) cmd_add "$@" ;;
        remove|rm) cmd_remove "$@" ;;
        check|c) cmd_check "$@" ;;
        diff|d) cmd_diff ;;
        edit|e) cmd_edit ;;
        help|h|--help|-h) usage ;;
        *) error "Unknown command: $cmd"; usage; exit 1 ;;
      esac
    }

    main "$@"
  '';
}
