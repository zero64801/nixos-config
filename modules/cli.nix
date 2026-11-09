{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.cli;

  nh = pkgs.symlinkJoin {
    inherit (pkgs.nh) pname version;
    paths = [ pkgs.nh ];
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    # Otherwise nh hands its root commands the caller's PATH, where a user writable directory comes before the system.
    postBuild = "wrapProgram $out/bin/nh --set NH_PRESERVE_ENV 0";
    meta = { inherit (pkgs.nh.meta) description mainProgram; };
  };

  activate = pkgs.writeShellApplication {
    name = "nixos-activate";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: nixos-activate /nix/store/...-nixos-system-... [switch|boot|test]" >&2
        exit 2
      fi

      system=$1
      action=''${2:-switch}
      case "$action" in
        switch | boot | test) ;;
        *)
          echo "nixos-activate: unknown action $action" >&2
          exit 2
          ;;
      esac

      # A link could be repointed after the request was shown, a store path cannot change.
      if [ "$(readlink -f -- "$system")" != "$system" ] || [[ $system != /nix/store/* ]]; then
        echo "nixos-activate: give the system's store path itself, not a link to it" >&2
        exit 1
      fi
      if [ ! -x "$system/bin/switch-to-configuration" ]; then
        echo "nixos-activate: $system is not a NixOS system" >&2
        exit 1
      fi
      if [ "$(id -u)" -ne 0 ]; then
        echo "nixos-activate: run it as root" >&2
        exit 1
      fi

      if [ "$action" != test ]; then
        ${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$system"
      fi
      exec "$system/bin/switch-to-configuration" "$action"
    '';
  };

  rebuild = pkgs.writeShellApplication {
    name = "rebuild";
    runtimeInputs = [ nh pkgs.coreutils pkgs.gnugrep pkgs.jq ];
    text = ''
      action=switch
      case "''${1:-}" in
        switch | boot | test)
          action=$1
          shift
          ;;
      esac
      mixed=0
      args=()
      for arg in "$@"; do
        if [ "$arg" = --mixed ]; then
          mixed=1
        else
          args+=("$arg")
        fi
      done

      runtime=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
      mkdir -p "$runtime/rebuild"
      out=$(mktemp -d "$runtime/rebuild/XXXXXX")
      trap 'rm -rf "$out"' EXIT

      # Named outright rather than taken from whatever hostname nh happens to see.
      ${cfg.rebuildNh}/bin/nh os build --hostname ${config.networking.hostName} --out-link "$out/system" "''${args[@]}"
      system=$(readlink -f "$out/system")

      # An update changes hundreds of things, a config change hiding among them would not stand out in the diff.
      running=/run/current-system/etc/nixos-sources.json
      built=$system/etc/nixos-sources.json
      if [ "$mixed" = 0 ] && [ -e "$running" ] && [ -e "$built" ] \
        && [ "$(jq -r .inputs "$running")" != "$(jq -r .inputs "$built")" ] \
        && [ "$(jq -r .config "$running")" != "$(jq -r .config "$built")" ]; then
        echo "rebuild: this build updates flake inputs and changes your config at once, so touch-guard would show both in one diff." >&2
        echo "  Split it into two rebuilds, the update alone and the config change alone, for example with git stash." >&2
        echo "  To take both together anyway: rebuild --mixed" >&2
        exit 1
      fi

      # setuid cannot raise privileges under no_new_privs, while run0 asks polkit instead.
      if grep -q '^NoNewPrivs:[[:space:]]*1' /proc/self/status; then
        /run/current-system/sw/bin/run0 ${activate}/bin/nixos-activate "$system" "$action"
      else
        /run/wrappers/bin/sudo ${activate}/bin/nixos-activate "$system" "$action"
      fi
    '';
  };
in
{
  options.my.cli = {
    enable = lib.mkEnableOption "nh as the rebuild and garbage collection front end";

    rebuildNh = lib.mkOption {
      type = lib.types.package;
      default = nh;
      defaultText = lib.literalExpression "config.programs.nh.package";
      description = "The nh rebuild evaluates and builds with. Its out link goes under $XDG_RUNTIME_DIR/rebuild.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.nh = {
      enable = true;
      package = nh;
      flake = config.my.flakePath;

      # nix.gc's --delete-older-than keeps no fixed count, so a week without switching leaves nothing to roll back to.
      # Result links stay because some are live references, such as an MCP server registered by its result path.
      clean = {
        enable = true;
        extraArgs = "--keep 5 --keep-since 7d --no-gcroots";
      };
    };

    environment.systemPackages = [
      activate
      rebuild
    ];

    environment.etc."nixos-sources.json".text = builtins.toJSON {
      inputs = builtins.hashFile "sha256" "${inputs.self}/flake.lock";
      config = builtins.unsafeDiscardStringContext "${
        builtins.path {
          path = inputs.self;
          name = "config-source";
          filter = path: _: !(lib.elem (baseNameOf path) [ "flake.lock" "pins.json" ]);
        }
      }";
    };

    nix.gc.automatic = false;
  };
}
