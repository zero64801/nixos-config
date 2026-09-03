{ writeShellApplication, util, curl, jq, git }:

writeShellApplication {
  name = "addon-pin";
  runtimeInputs = [ curl jq git ];
  text = ''
    ${util.cliPrelude}

    AMO="https://addons.mozilla.org/api/v5/addons/addon"

    # Pins live in a firefox-addons.json next to the module that consumes them, the same way pin treats sources.json.
    pins_files() {
      if [ -n "''${PINS_FILE:-}" ]; then
        [ -f "$PINS_FILE" ] || die "no such file: $PINS_FILE"
        echo "$PINS_FILE"
        return
      fi
      local root
      root=$(git rev-parse --show-toplevel 2>/dev/null) \
        || die "not inside the flake repo. Use --file PATH."
      git -C "$root" ls-files --cached --others --exclude-standard -- '*firefox-addons.json' \
        | while IFS= read -r f; do echo "$root/$f"; done
    }

    # AMO publishes the sha256 of every file it serves, so the pin never depends on a hash this script computed from its own download.
    fetch_latest() {
      local slug=$1 body
      body=$(curl -fsSL --max-time 30 "$AMO/$slug/") \
        || { warn "AMO lookup failed for $slug"; return 1; }
      echo "$body" | jq -e '{
        version: .current_version.version,
        url:     .current_version.file.url,
        sha256:  (.current_version.file.hash | sub("^sha256:"; "")),
        addonId: .guid
      } | select(.version != null and .url != null and .sha256 != null)' \
        || { warn "unexpected AMO response for $slug"; return 1; }
    }

    cmd_list() {
      local root f name slug pinned latest found=false
      root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
      echo -e "''${bold}Firefox addons''${reset}\n"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=true
        echo -e "  ''${blue}''${f#"$root"/}''${reset}"
        while IFS=$'\t' read -r name slug pinned; do
          latest=$(fetch_latest "$slug" | jq -r '.version' 2>/dev/null || echo "?")
          if [ "$pinned" = "$latest" ]; then
            printf "    %-26s %-14s ''${green}current''${reset}\n" "$name" "$pinned"
          else
            printf "    %-26s %-14s ''${yellow}%s available''${reset}\n" "$name" "$pinned" "$latest"
          fi
        done < <(jq -r 'to_entries[] | [.key, .value.slug, .value.version] | @tsv' "$f")
      done < <(pins_files)
      [ "$found" = "true" ] || echo -e "  ''${DIM}No firefox-addons.json files found.''${NC}"
    }

    cmd_update() {
      local force=false targets=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --force|-f) force=true; shift ;;
          *) targets+=("$1"); shift ;;
        esac
      done

      local f name slug pinned frozen latest new_version tmp updated=0
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        while IFS=$'\t' read -r name slug pinned frozen; do
          if [ ''${#targets[@]} -gt 0 ]; then
            local wanted=false t
            for t in "''${targets[@]}"; do [ "$t" = "$name" ] && wanted=true; done
            [ "$wanted" = "true" ] || continue
          fi

          if [ -n "$frozen" ] && [ "$force" != "true" ]; then
            warn "Skipping ''${bold}$name''${reset} (frozen: $frozen). Use --force to override."
            continue
          fi

          latest=$(fetch_latest "$slug") || continue
          new_version=$(echo "$latest" | jq -r '.version')
          [ "$new_version" != "$pinned" ] || continue

          tmp=$(mktemp)
          jq --arg n "$name" --argjson v "$latest" \
            '.[$n] += { version: $v.version, url: $v.url, sha256: $v.sha256, addonId: $v.addonId }' \
            "$f" > "$tmp" && mv "$tmp" "$f"

          ok "$name ''${DIM}$pinned''${NC} -> ''${bold}$new_version''${reset}"
          updated=$((updated + 1))
        done < <(jq -r 'to_entries[] | [.key, .value.slug, .value.version, (.value.frozen // "")] | @tsv' "$f")
      done < <(pins_files)

      if [ "$updated" -eq 0 ]; then
        info "All addons already current."
      else
        info "$updated updated. Review with ''${bold}git diff''${reset} before rebuilding."
      fi
    }

    usage() {
      echo -e "''${bold}addon-pin''${reset} — Pin Firefox addons straight from addons.mozilla.org

''${green}''${bold}Usage:''${reset} addon-pin [COMMAND] [ARGS]

''${bold}Commands:''${reset}
  list                  Compare pinned versions against AMO
  update [NAME...]      Update pins (all, or only the named addons)

''${bold}Options:''${reset}
  --force, -f           Update entries marked frozen
  --file PATH           Operate on one pins file instead of discovering them

''${bold}Notes:''${reset}
  Every firefox-addons.json tracked in the repo is discovered automatically.
  Pins record the sha256 AMO publishes for each file, so an addon that is
  altered after pinning fails the build instead of installing silently.
  Add ''${DIM}\"frozen\": \"reason\"''${NC} to an entry to hold it back."
    }

    main() {
      local args=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --file) PINS_FILE=$2; shift 2 ;;
          -h|--help) usage; exit 0 ;;
          *) args+=("$1"); shift ;;
        esac
      done
      set -- "''${args[@]:-}"

      case "''${1:-list}" in
        list) cmd_list ;;
        update) shift || true; cmd_update "$@" ;;
        *) usage; exit 1 ;;
      esac
    }

    main "$@"
  '';
}
