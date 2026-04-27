{ config, pkgs, lib, inputs, ... }:

let
  nyx-rebuild = pkgs.writeShellApplication {
    name = "nyx-rebuild";
    runtimeInputs = with pkgs; [ coreutils gnugrep gnused jq nix nixos-rebuild ];
    text = ''
      set -euo pipefail

      FLAKE_PATH="''${NYX_FLAKE_PATH:-$HOME/nixos}"
      HOST="''${NYX_HOST:-$(hostname)}"

      [[ "$#" -ge 1 ]] || { echo "usage: nyx-rebuild <switch|boot|test|build|...> [extra args]" >&2; exit 1; }
      action="$1"; shift

      # Read what the host's resolved config wants.
      expected_subs=$(nix eval --raw \
        "$FLAKE_PATH#nixosConfigurations.$HOST.config.nix.settings.substituters" \
        --apply 'subs: builtins.concatStringsSep "\n" subs' 2>/dev/null || echo "")
      expected_keys=$(nix eval --raw \
        "$FLAKE_PATH#nixosConfigurations.$HOST.config.nix.settings.trusted-public-keys" \
        --apply 'keys: builtins.concatStringsSep "\n" keys' 2>/dev/null || echo "")

      # Read what /etc/nix/nix.conf already has.
      current_subs=$(awk -F= '/^[[:space:]]*(extra-)?substituters[[:space:]]*=/ {sub(/^[^=]+=[[:space:]]*/, ""); print}' /etc/nix/nix.conf | tr ' ' '\n' | sed '/^$/d' | sort -u)
      current_keys=$(awk -F= '/^[[:space:]]*(extra-)?trusted-public-keys[[:space:]]*=/ {sub(/^[^=]+=[[:space:]]*/, ""); print}' /etc/nix/nix.conf | tr ' ' '\n' | sed '/^$/d' | sort -u)

      flags=()
      while IFS= read -r sub; do
        [[ -n "$sub" ]] || continue
        if ! grep -qFx "$sub" <<< "$current_subs"; then
          echo "nyx-rebuild: bootstrapping substituter: $sub" >&2
          flags+=(--option extra-substituters "$sub")
        fi
      done <<< "$expected_subs"
      while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if ! grep -qFx "$key" <<< "$current_keys"; then
          echo "nyx-rebuild: bootstrapping trusted key: $key" >&2
          flags+=(--option extra-trusted-public-keys "$key")
        fi
      done <<< "$expected_keys"

      exec sudo nixos-rebuild "$action" --flake "$FLAKE_PATH#$HOST" "''${flags[@]}" "$@"
    '';
  };
in
{
  nixpkgs = {
    config.allowUnfree = true;
    overlays = [ (import ../pkgs/default.nix inputs) ];
  };

  environment.systemPackages = [ nyx-rebuild ];

  nix = {
    #package = pkgs.lix;
    channel.enable = false;

    settings = {
      experimental-features = [ "nix-command" "flakes" "pipe-operator" ];
      # nixpkgs lib still uses `or` as an identifier in places.
      # Lix warns unless we acknowledge it via deprecated-features.
      extra-deprecated-features = [ "or-as-identifier" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "@wheel" ];

      substituters = [ "https://nix-community.cachix.org" ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    gc = {
      persistent = true;
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };
}
