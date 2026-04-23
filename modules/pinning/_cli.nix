{
  writeShellApplication,
  lib,
  coreutils,
  gnugrep,
  gnused,
  jq,
  nix,
  fzf,
  git,
  flakePath ? null,
  pinsFilePath ? null,
}:

writeShellApplication {
  name = "nyx-pin";

  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    jq
    nix
    fzf
    git
  ];

  text = ''
    set -euo pipefail

    FLAKE_PATH="''${NYX_FLAKE_PATH:-${if flakePath != null then flakePath else ""}}"
    PINS_FILE="''${NYX_PINS_FILE:-${if pinsFilePath != null then pinsFilePath else ""}}"

    red=$(tput setaf 1 || echo "")
    green=$(tput setaf 2 || echo "")
    yellow=$(tput setaf 3 || echo "")
    blue=$(tput setaf 4 || echo "")
    cyan=$(tput setaf 6 || echo "")
    reset=$(tput sgr0 || echo "")
    bold=$(tput bold || echo "")

    DIM='\x1b[2m'
    NC='\x1b[0m'

    # ── helpers ────────────────────────────────────────────────────────
    die()  { echo -e "''${red}Error:''${reset} $*" >&2; exit 1; }
    info() { echo -e "''${blue}::''${reset} $*"; }
    ok()   { echo -e "''${green}✓''${reset} $*"; }
    warn() { echo -e "''${yellow}⚠''${reset} $*"; }

    ensure_paths() {
      [[ -n "$FLAKE_PATH" ]]  || die "FLAKE_PATH not set. Set nyx.pinning.flakePath or NYX_FLAKE_PATH."
      [[ -d "$FLAKE_PATH" ]]  || die "Flake directory not found: $FLAKE_PATH"
      [[ -f "$FLAKE_PATH/flake.lock" ]] || die "No flake.lock found in $FLAKE_PATH"
      [[ -n "$PINS_FILE" ]]   || die "PINS_FILE not set. Set nyx.pinning.pinsFile or NYX_PINS_FILE."
      # Ensure pins file exists
      if [[ ! -f "$PINS_FILE" ]]; then
        mkdir -p "$(dirname "$PINS_FILE")"
        echo '{"pins":{}}' > "$PINS_FILE"
      fi
    }

    # Read flake.lock and extract info for an input
    lock_file() { cat "$FLAKE_PATH/flake.lock"; }

    # Get all top-level (direct) input names from flake.lock
    get_direct_inputs() {
      lock_file | jq -r '.nodes.root.inputs | keys[]' | sort
    }

    # Get the locked node for an input
    get_locked_node() {
      local input="$1"
      # Resolve indirect references (root.inputs may point to a key that differs)
      local node_key
      node_key=$(lock_file | jq -r --arg i "$input" '.nodes.root.inputs[$i] // empty')
      [[ -n "$node_key" ]] || return 1
      lock_file | jq --arg k "$node_key" '.nodes[$k]'
    }

    get_locked_rev() {
      local input="$1"
      get_locked_node "$input" | jq -r '.locked.rev // empty'
    }

    get_locked_last_modified() {
      local input="$1"
      local ts
      ts=$(get_locked_node "$input" | jq -r '.locked.lastModified // empty')
      if [[ -n "$ts" ]]; then
        date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts"
      fi
    }

    get_locked_nar_hash() {
      local input="$1"
      get_locked_node "$input" | jq -r '.locked.narHash // empty'
    }

    # Reconstruct a flake reference with a specific rev for override
    get_input_ref_with_rev() {
      local input="$1"
      local rev="$2"
      local node
      node=$(get_locked_node "$input") || die "Input '$input' not found in flake.lock"

      local type owner repo host dir ref_str
      type=$(echo "$node" | jq -r '.original.type // empty')

      case "$type" in
        github)
          owner=$(echo "$node" | jq -r '.original.owner')
          repo=$(echo "$node" | jq -r '.original.repo')
          dir=$(echo "$node" | jq -r '.original.dir // empty')
          ref_str="github:$owner/$repo/$rev"
          if [[ -n "$dir" ]]; then
            ref_str="$ref_str?dir=$dir"
          fi
          echo "$ref_str"
          ;;
        gitlab)
          owner=$(echo "$node" | jq -r '.original.owner')
          repo=$(echo "$node" | jq -r '.original.repo')
          host=$(echo "$node" | jq -r '.original.host // empty')
          dir=$(echo "$node" | jq -r '.original.dir // empty')
          if [[ -n "$host" ]]; then
            ref_str="gitlab:$owner/$repo/$rev?host=$host"
          else
            ref_str="gitlab:$owner/$repo/$rev"
          fi
          if [[ -n "$dir" ]]; then
            if [[ "$ref_str" == *"?"* ]]; then
              ref_str="$ref_str&dir=$dir"
            else
              ref_str="$ref_str?dir=$dir"
            fi
          fi
          echo "$ref_str"
          ;;
        tarball)
          # For tarballs (like lix on forgejo/gitea), construct a new URL
          # with the target rev substituted in. The locked URL contains
          # the *current* rev in both the archive path and a `rev=` query
          # param; we strip the query (narHash/rev) and swap any 40-char
          # hex in the path with the target rev. Works for github/gitlab/
          # gitea/forgejo archive endpoints.
          local url base new
          url=$(echo "$node" | jq -r '.locked.url // empty')
          [[ -n "$url" ]] || die "Cannot determine URL for tarball input '$input'"
          base="''${url%%\?*}"
          new=$(echo "$base" | sed -E "s|[a-f0-9]{40}|$rev|g")
          if [[ "$new" == "$base" ]]; then
            warn "Could not substitute rev in tarball URL for '$input' — pin may not take effect"
          fi
          echo "$new"
          ;;
        sourcehut)
          owner=$(echo "$node" | jq -r '.original.owner')
          repo=$(echo "$node" | jq -r '.original.repo')
          echo "sourcehut:$owner/$repo/$rev"
          ;;
        *)
          die "Unsupported input type '$type' for input '$input'. Pin manually."
          ;;
      esac
    }

    # ── pins.json operations ───────────────────────────────────────────
    get_pin() {
      local input="$1"
      jq -r --arg i "$input" '.pins[$i] // empty' "$PINS_FILE"
    }

    get_pin_type() {
      local input="$1"
      jq -r --arg i "$input" '.pins[$i].type // empty' "$PINS_FILE"
    }

    get_pin_rev() {
      local input="$1"
      jq -r --arg i "$input" '.pins[$i].rev // empty' "$PINS_FILE"
    }

    get_pin_reason() {
      local input="$1"
      jq -r --arg i "$input" '.pins[$i].reason // empty' "$PINS_FILE"
    }

    get_pin_date() {
      local input="$1"
      jq -r --arg i "$input" '.pins[$i].date // empty' "$PINS_FILE"
    }

    set_pin() {
      local input="$1" type="$2" rev="$3" reason="''${4:-}"
      local date_str
      date_str=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      local tmp
      tmp=$(mktemp)
      jq --arg i "$input" --arg t "$type" --arg r "$rev" --arg reason "$reason" --arg d "$date_str" '
        .pins[$i] = {
          type: $t,
          rev: $r,
          date: $d
        } | if $reason != "" then .pins[$i].reason = $reason else . end
      ' "$PINS_FILE" > "$tmp" && mv "$tmp" "$PINS_FILE"
    }

    remove_pin() {
      local input="$1"
      local tmp
      tmp=$(mktemp)
      jq --arg i "$input" 'del(.pins[$i])' "$PINS_FILE" > "$tmp" && mv "$tmp" "$PINS_FILE"
    }

    get_all_pinned_inputs() {
      jq -r '.pins | keys[]' "$PINS_FILE" 2>/dev/null
    }

    # ── commands ───────────────────────────────────────────────────────

    cmd_status() {
      ensure_paths
      echo -e "''${bold}Flake Input Pins''${reset}"
      echo -e "''${DIM}Flake: $FLAKE_PATH | Pins: $PINS_FILE''${NC}\n"

      local inputs
      inputs=$(get_direct_inputs)

      local pinned_count=0
      local frozen_count=0

      printf "  ''${bold}%-22s %-10s %-12s %-20s %s''${reset}\n" "INPUT" "STATUS" "REV" "LOCKED DATE" "REASON"
      echo -e "  ''${DIM}$(printf '─%.0s' $(seq 1 90))''${NC}"

      while IFS= read -r input; do
        local pin_type rev locked_rev locked_date reason status_str rev_display

        pin_type=$(get_pin_type "$input")
        locked_rev=$(get_locked_rev "$input")
        locked_date=$(get_locked_last_modified "$input")
        rev_display="''${locked_rev:0:12}"

        case "$pin_type" in
          frozen)
            status_str="''${cyan}frozen''${reset}"
            reason=$(get_pin_reason "$input")
            frozen_count=$((frozen_count + 1))
            ;;
          pinned)
            status_str="''${yellow}pinned''${reset}"
            rev=$(get_pin_rev "$input")
            rev_display="''${rev:0:12}"
            reason=$(get_pin_reason "$input")
            pinned_count=$((pinned_count + 1))
            ;;
          *)
            status_str="''${green}tracking''${reset}"
            reason=""
            ;;
        esac

        local reason_display=""
        if [[ -n "$reason" ]]; then
          reason_display="''${DIM}$reason''${NC}"
        fi

        printf "  %-22s %-21s %-12s %-20s %b\n" \
          "$input" "$status_str" "$rev_display" "''${locked_date:-—}" "$reason_display"
      done <<< "$inputs"

      echo
      echo -e "  ''${DIM}$frozen_count frozen, $pinned_count pinned, $(echo "$inputs" | wc -l) total inputs''${NC}"
    }

    cmd_freeze() {
      ensure_paths
      local input="''${1:-}"
      local reason=""

      # Parse flags
      shift || true
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          -r|--reason) reason="$2"; shift 2 ;;
          *) reason="$*"; break ;;
        esac
      done

      if [[ -z "$input" ]]; then
        # Interactive: pick from non-pinned inputs
        local candidates
        candidates=$(get_direct_inputs | while IFS= read -r i; do
          local pt
          pt=$(get_pin_type "$i")
          if [[ -z "$pt" ]]; then
            echo "$i"
          fi
        done)
        if [[ -z "$candidates" ]]; then
          die "All inputs are already pinned or frozen."
        fi
        input=$(echo "$candidates" | fzf --prompt="Select input to freeze: " --height=~20) || exit 0
      fi

      local rev
      rev=$(get_locked_rev "$input")
      [[ -n "$rev" ]] || die "Cannot determine current revision for '$input'"

      if [[ -z "$reason" ]]; then
        echo -n -e "''${DIM}Reason (optional, Enter to skip): ''${NC}"
        read -r reason
      fi

      set_pin "$input" "frozen" "$rev" "$reason"

      ok "Frozen ''${bold}$input''${reset} at rev ''${cyan}''${rev:0:12}''${reset}"
      if [[ -n "$reason" ]]; then
        echo -e "  ''${DIM}Reason: $reason''${NC}"
      fi
    }

    cmd_pin() {
      ensure_paths
      local input="''${1:-}"
      local rev="''${2:-}"
      local reason=""

      shift 2 2>/dev/null || shift "$#"
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          -r|--reason) reason="$2"; shift 2 ;;
          *) reason="$*"; break ;;
        esac
      done

      if [[ -z "$input" ]]; then
        input=$(get_direct_inputs | fzf --prompt="Select input to pin: " --height=~20) || exit 0
      fi

      # Validate input exists
      get_locked_node "$input" > /dev/null || die "Input '$input' not found in flake.lock"

      if [[ -z "$rev" ]]; then
        local current_rev
        current_rev=$(get_locked_rev "$input")
        echo -e "Current rev: ''${cyan}''${current_rev:-unknown}''${reset}"
        echo -n -e "Enter revision to pin to (or Enter for current): "
        read -r rev
        if [[ -z "$rev" ]]; then
          rev="$current_rev"
        fi
      fi

      [[ -n "$rev" ]] || die "No revision specified"

      if [[ -z "$reason" ]]; then
        echo -n -e "''${DIM}Reason (optional, Enter to skip): ''${NC}"
        read -r reason
      fi

      # Actually lock the input to the specified rev
      info "Locking ''${bold}$input''${reset} to rev ''${cyan}''${rev:0:12}''${reset}..."
      local ref
      ref=$(get_input_ref_with_rev "$input" "$rev")
      nix flake lock "$FLAKE_PATH" --override-input "$input" "$ref"

      set_pin "$input" "pinned" "$rev" "$reason"

      ok "Pinned ''${bold}$input''${reset} to rev ''${cyan}''${rev:0:12}''${reset}"
      if [[ -n "$reason" ]]; then
        echo -e "  ''${DIM}Reason: $reason''${NC}"
      fi
    }

    cmd_unpin() {
      ensure_paths
      local input="''${1:-}"

      if [[ -z "$input" ]]; then
        local pinned
        pinned=$(get_all_pinned_inputs)
        if [[ -z "$pinned" ]]; then
          die "No inputs are currently pinned or frozen."
        fi
        input=$(echo "$pinned" | fzf --prompt="Select input to unpin: " --height=~20) || exit 0
      fi

      local pin_type
      pin_type=$(get_pin_type "$input")
      if [[ -z "$pin_type" ]]; then
        die "Input '$input' is not pinned or frozen."
      fi

      remove_pin "$input"
      ok "Unpinned ''${bold}$input''${reset} (was $pin_type)"
      echo -e "  ''${DIM}This input will be updated on next 'nyx-pin update'.''${NC}"
    }

    cmd_update() {
      ensure_paths
      local specific_inputs=()
      local force=false
      local dry_run=false

      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --force|-f) force=true; shift ;;
          --dry-run|-n) dry_run=true; shift ;;
          *) specific_inputs+=("$1"); shift ;;
        esac
      done

      # Collect pinned/frozen inputs
      local pinned_inputs
      pinned_inputs=$(get_all_pinned_inputs)

      # If specific inputs given, update only those; otherwise update all non-pinned
      if [[ ''${#specific_inputs[@]} -gt 0 ]]; then
        for inp in "''${specific_inputs[@]}"; do
          local pt
          pt=$(get_pin_type "$inp")
          if [[ -n "$pt" ]] && [[ "$force" != "true" ]]; then
            warn "Skipping ''${bold}$inp''${reset} ($pt). Use --force to override."
            continue
          fi
          if [[ "$dry_run" == "true" ]]; then
            info "[dry-run] Would update: $inp"
          else
            info "Updating ''${bold}$inp''${reset}..."
            nix flake update "$inp" --flake "$FLAKE_PATH"
            ok "Updated $inp"
          fi
        done
      else
        # Build args: update all, then restore pins
        if [[ "$dry_run" == "true" ]]; then
          info "[dry-run] Would update all inputs..."
          if [[ -n "$pinned_inputs" ]]; then
            echo -e "\n''${DIM}Would skip (frozen/pinned):''${NC}"
            while IFS= read -r pi; do
              local pt
              pt=$(get_pin_type "$pi")
              local pr
              pr=$(get_pin_rev "$pi")
              echo -e "  ''${cyan}$pi''${reset} ($pt @ ''${pr:0:12})"
            done <<< "$pinned_inputs"
          fi
          return
        fi

        # Save current pinned revisions before update
        declare -A saved_revs
        declare -A saved_types
        if [[ -n "$pinned_inputs" ]]; then
          while IFS= read -r pi; do
            local pt
            pt=$(get_pin_type "$pi")
            saved_types["$pi"]="$pt"
            # Both frozen and pinned use pins.json's rev — it's the
            # authoritative record. If the lockfile drifted (e.g., the
            # user ran vanilla `nix flake update` before), we still
            # restore to the pin's rev, not whatever happens to be
            # locked now.
            saved_revs["$pi"]=$(get_pin_rev "$pi")
          done <<< "$pinned_inputs"
        fi

        info "Updating all flake inputs..."
        nix flake update --flake "$FLAKE_PATH"
        ok "Flake inputs updated"

        # Restore pinned/frozen inputs
        if [[ -n "$pinned_inputs" ]]; then
          echo
          info "Restoring pinned/frozen inputs..."
          while IFS= read -r pi; do
            local target_rev="''${saved_revs[$pi]:-}"
            local pin_type="''${saved_types[$pi]:-}"
            if [[ -n "$target_rev" ]]; then
              local ref
              ref=$(get_input_ref_with_rev "$pi" "$target_rev")
              nix flake lock "$FLAKE_PATH" --override-input "$pi" "$ref"
              ok "Restored ''${bold}$pi''${reset} ($pin_type @ ''${target_rev:0:12})"
            else
              warn "Could not restore $pi — no saved revision"
            fi
          done <<< "$pinned_inputs"
        fi
      fi

      echo
      ok "Done. Pinned/frozen inputs preserved."
    }

    cmd_why() {
      ensure_paths
      local input="''${1:-}"

      if [[ -z "$input" ]]; then
        local pinned
        pinned=$(get_all_pinned_inputs)
        if [[ -z "$pinned" ]]; then
          echo -e "''${green}No inputs are pinned or frozen.''${reset}"
          return
        fi
        input=$(echo "$pinned" | fzf --prompt="Select input: " --height=~20) || exit 0
      fi

      local pin_type rev reason date_str
      pin_type=$(get_pin_type "$input")

      if [[ -z "$pin_type" ]]; then
        echo -e "''${bold}$input''${reset} is ''${green}tracking''${reset} (not pinned or frozen)"
        return
      fi

      rev=$(get_pin_rev "$input")
      reason=$(get_pin_reason "$input")
      date_str=$(get_pin_date "$input")

      echo -e "''${bold}$input''${reset}"
      echo -e "  Status:  $(
        case "$pin_type" in
          frozen) echo -e "''${cyan}frozen''${reset}" ;;
          pinned) echo -e "''${yellow}pinned''${reset}" ;;
        esac
      )"
      echo -e "  Rev:     ''${cyan}$rev''${reset}"
      echo -e "  Since:   ''${date_str:-unknown}"
      if [[ -n "$reason" ]]; then
        echo -e "  Reason:  $reason"
      else
        echo -e "  Reason:  ''${DIM}(none)''${NC}"
      fi

      # Show current locked rev for comparison
      local locked_rev
      locked_rev=$(get_locked_rev "$input")
      if [[ "$locked_rev" != "$rev" ]]; then
        echo -e "\n  ''${yellow}⚠ Lock file rev differs:''${reset} ''${locked_rev:0:12}"
        echo -e "  ''${DIM}Run 'nyx-pin update' to reconcile.''${NC}"
      fi
    }

    cmd_set_reason() {
      ensure_paths
      local input="''${1:-}"
      local reason="''${2:-}"

      if [[ -z "$input" ]]; then
        local pinned
        pinned=$(get_all_pinned_inputs)
        [[ -n "$pinned" ]] || die "No inputs are pinned or frozen."
        input=$(echo "$pinned" | fzf --prompt="Select input: " --height=~20) || exit 0
      fi

      local pin_type
      pin_type=$(get_pin_type "$input")
      [[ -n "$pin_type" ]] || die "'$input' is not pinned or frozen."

      if [[ -z "$reason" ]]; then
        echo -n "Enter reason: "
        read -r reason
      fi

      local tmp
      tmp=$(mktemp)
      jq --arg i "$input" --arg r "$reason" '.pins[$i].reason = $r' "$PINS_FILE" > "$tmp" && mv "$tmp" "$PINS_FILE"
      ok "Updated reason for ''${bold}$input''${reset}"
    }

    cmd_history() {
      ensure_paths
      local input="''${1:-}"

      if ! git -C "$FLAKE_PATH" rev-parse --git-dir &>/dev/null; then
        die "Not a git repository: $FLAKE_PATH"
      fi

      local rel_pins
      rel_pins=$(realpath --relative-to="$FLAKE_PATH" "$PINS_FILE" 2>/dev/null || basename "$PINS_FILE")

      echo -e "''${bold}Pin History''${reset}"
      echo -e "''${DIM}Source: git log of $rel_pins''${NC}\n"

      if [[ -n "$input" ]]; then
        git -C "$FLAKE_PATH" log --oneline --follow -p -- "$rel_pins" 2>/dev/null | \
          grep -A5 -B2 "\"$input\"" | head -60 || \
          echo -e "''${DIM}No history found for '$input'.''${NC}"
      else
        git -C "$FLAKE_PATH" log --oneline --follow -- "$rel_pins" 2>/dev/null | head -30 || \
          echo -e "''${DIM}No history found for pins file.''${NC}"
      fi
    }

    cmd_diff() {
      ensure_paths
      local input="''${1:-}"

      if [[ -z "$input" ]]; then
        local pinned
        pinned=$(get_all_pinned_inputs)
        [[ -n "$pinned" ]] || die "No inputs are pinned or frozen."
        input=$(echo "$pinned" | fzf --prompt="Select input to diff: " --height=~20) || exit 0
      fi

      local pin_type pinned_rev
      pin_type=$(get_pin_type "$input")
      pinned_rev=$(get_pin_rev "$input")

      if [[ -z "$pin_type" ]]; then
        echo -e "''${bold}$input''${reset} is not pinned — nothing to compare."
        return
      fi

      local locked_rev
      locked_rev=$(get_locked_rev "$input")

      echo -e "''${bold}$input''${reset} ($pin_type)"
      echo -e "  Pinned rev: ''${cyan}''${pinned_rev:0:12}''${reset}"
      echo -e "  Locked rev: ''${cyan}''${locked_rev:0:12}''${reset}"

      if [[ "$pinned_rev" == "$locked_rev" ]]; then
        echo -e "\n  ''${green}Lock matches pin — in sync.''${reset}"
      else
        echo -e "\n  ''${yellow}Lock differs from pin.''${reset}"
        echo -e "  ''${DIM}Run 'nyx-pin update' to restore pin, or 'nyx-pin unpin $input' to track latest.''${NC}"
      fi

      # Try to show what latest would be by checking the original URL
      local node
      node=$(get_locked_node "$input")
      local orig_type
      orig_type=$(echo "$node" | jq -r '.original.type // empty')

      if [[ "$orig_type" == "github" ]] || [[ "$orig_type" == "gitlab" ]]; then
        local owner repo
        owner=$(echo "$node" | jq -r '.original.owner')
        repo=$(echo "$node" | jq -r '.original.repo')
        local ref_branch
        ref_branch=$(echo "$node" | jq -r '.original.ref // "HEAD"')
        echo -e "\n  ''${DIM}Source: $orig_type:$owner/$repo (ref: $ref_branch)''${NC}"
        echo -e "  ''${DIM}To see what you're missing, check the repo's commit log since ''${pinned_rev:0:12}.''${NC}"
      fi
    }

    cmd_check() {
      ensure_paths
      echo -e "''${bold}Pin Integrity Check''${reset}\n"

      local all_ok=true
      local pinned_inputs
      pinned_inputs=$(get_all_pinned_inputs)

      if [[ -z "$pinned_inputs" ]]; then
        echo -e "''${green}No pins defined — nothing to check.''${reset}"
        return
      fi

      while IFS= read -r input; do
        local pin_type pin_rev locked_rev
        pin_type=$(get_pin_type "$input")
        pin_rev=$(get_pin_rev "$input")
        locked_rev=$(get_locked_rev "$input")

        # Check input still exists in flake.lock
        if [[ -z "$locked_rev" ]]; then
          echo -e "  ''${red}✗''${reset} ''${bold}$input''${reset} — not found in flake.lock (stale pin?)"
          all_ok=false
          continue
        fi

        if [[ "$pin_rev" == "$locked_rev" ]]; then
          echo -e "  ''${green}✓''${reset} ''${bold}$input''${reset} ($pin_type @ ''${pin_rev:0:12})"
        else
          echo -e "  ''${yellow}⚠''${reset} ''${bold}$input''${reset} ($pin_type) — expected ''${pin_rev:0:12}, locked ''${locked_rev:0:12}"
          all_ok=false
        fi
      done <<< "$pinned_inputs"

      echo
      if [[ "$all_ok" == "true" ]]; then
        ok "All pins are in sync with flake.lock"
      else
        warn "Some pins are out of sync. Run ''${bold}nyx-pin update''${reset} to reconcile."
      fi
    }

    cmd_restore() {
      ensure_paths
      local input="''${1:-}"

      if [[ -n "$input" ]]; then
        local pin_type pin_rev
        pin_type=$(get_pin_type "$input")
        pin_rev=$(get_pin_rev "$input")
        [[ -n "$pin_type" ]] || die "'$input' is not pinned or frozen."

        info "Restoring ''${bold}$input''${reset} to $pin_type rev ''${cyan}''${pin_rev:0:12}''${reset}..."
        local ref
        ref=$(get_input_ref_with_rev "$input" "$pin_rev")
        nix flake lock "$FLAKE_PATH" --override-input "$input" "$ref"
        ok "Restored $input"
      else
        # Restore all pins
        local pinned_inputs
        pinned_inputs=$(get_all_pinned_inputs)
        [[ -n "$pinned_inputs" ]] || die "No inputs are pinned or frozen."

        info "Restoring all pinned/frozen inputs..."
        while IFS= read -r pi; do
          local pt pr
          pt=$(get_pin_type "$pi")
          pr=$(get_pin_rev "$pi")
          if [[ -n "$pr" ]]; then
            local ref
            ref=$(get_input_ref_with_rev "$pi" "$pr")
            nix flake lock "$FLAKE_PATH" --override-input "$pi" "$ref"
            ok "Restored ''${bold}$pi''${reset} ($pt @ ''${pr:0:12})"
          fi
        done <<< "$pinned_inputs"
      fi
    }

    cmd_list_json() {
      ensure_paths
      jq '.' "$PINS_FILE"
    }

    show_help() {
      echo -e "''${bold}nyx-pin''${reset} — Manage flake input pinning

''${green}''${bold}Usage:''${reset} nyx-pin [COMMAND] [OPTIONS] [ARGS]

''${green}''${bold}Commands:''${reset}
  ''${yellow}status, ls''${reset}                      Show all inputs with their pin/freeze status.
  ''${yellow}freeze <input>''${reset}                  Freeze an input at its current locked revision.
                                   Omit <input> to pick interactively with fzf.
  ''${yellow}pin <input> [rev]''${reset}               Pin an input to a specific git revision.
                                   Omit [rev] to be prompted (defaults to current).
  ''${yellow}unpin <input>''${reset}                   Remove a pin/freeze. Omit <input> for fzf selection.
  ''${yellow}update [inputs...]''${reset}              Update flake inputs, respecting all pins/freezes.
                                   If specific inputs are given, update only those.
    ''${DIM}--force, -f''${NC}                   Force-update even pinned/frozen inputs.
    ''${DIM}--dry-run, -n''${NC}                 Show what would happen without making changes.
  ''${yellow}restore [input]''${reset}                 Re-lock pinned/frozen inputs to their target revs.
                                   Useful after a manual 'nix flake update'.
  ''${yellow}check''${reset}                           Verify all pins match their flake.lock entries.
  ''${yellow}diff [input]''${reset}                    Compare pinned rev vs locked rev for an input.
  ''${yellow}why [input]''${reset}                     Show detailed info about why an input is pinned.
  ''${yellow}set-reason <input> [reason]''${reset}     Set or update the reason annotation for a pin.
  ''${yellow}history [input]''${reset}                 Show git history of pin changes.
  ''${yellow}config''${reset}                          Print the raw pins.json contents.
  ''${yellow}help''${reset}                            Show this help message.

''${green}''${bold}Pin Types:''${reset}
  ''${cyan}frozen''${reset}    Input stays at its current locked revision. Use when things
            are working and you don't want updates to break them.
  ''${yellow}pinned''${reset}    Input is locked to a specific revision. Use when you need
            an exact version (e.g., rolling back to a known-good commit).

''${green}''${bold}Workflow Examples:''${reset}

  ''${bold}Freeze nixpkgs so it won't update:''${reset}
    nyx-pin freeze nixpkgs --reason \"stable baseline\"

  ''${bold}Pin stylix to a specific old revision:''${reset}
    nyx-pin pin stylix abc123def456 --reason \"v2.0 broke my theme\"

  ''${bold}Update everything except pinned inputs:''${reset}
    nyx-pin update

  ''${bold}Force-update a frozen input anyway:''${reset}
    nyx-pin update nixpkgs --force

  ''${bold}Unfreeze nixpkgs and let it track latest again:''${reset}
    nyx-pin unpin nixpkgs

  ''${bold}Check that lock file matches all pins:''${reset}
    nyx-pin check

  ''${bold}Restore pins after an accidental 'nix flake update':''${reset}
    nyx-pin restore

  ''${bold}See why something is pinned:''${reset}
    nyx-pin why nixpkgs

  ''${bold}Dry-run to see what would update:''${reset}
    nyx-pin update --dry-run
"
      exit 0
    }

    # ── main ───────────────────────────────────────────────────────────
    main() {
      if [[ "$#" == '0' ]]; then
        show_help
      fi

      case "$1" in
        -h|--help|help)
          show_help
          ;;
        -v|--verbose)
          set -x
          shift
          main "$@"
          ;;
        status|ls|list)
          shift
          cmd_status "$@"
          ;;
        freeze)
          shift
          cmd_freeze "$@"
          ;;
        pin)
          shift
          cmd_pin "$@"
          ;;
        unpin|unfreeze|rm|remove)
          shift
          cmd_unpin "$@"
          ;;
        update|up)
          shift
          cmd_update "$@"
          ;;
        restore)
          shift
          cmd_restore "$@"
          ;;
        check|verify)
          shift
          cmd_check "$@"
          ;;
        diff)
          shift
          cmd_diff "$@"
          ;;
        why)
          shift
          cmd_why "$@"
          ;;
        set-reason|reason)
          shift
          cmd_set_reason "$@"
          ;;
        history|log)
          shift
          cmd_history "$@"
          ;;
        config)
          shift
          cmd_list_json "$@"
          ;;
        *)
          die "Unknown command: $1. Run 'nyx-pin help' for usage."
          ;;
      esac
    }

    main "$@"
  '';
}
