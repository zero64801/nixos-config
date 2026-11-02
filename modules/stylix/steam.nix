{ config, lib, pkgs, ... }:

let
  stylixEnabled = config.my.stylix.enable;

  adwaitaForSteam = pkgs.fetchFromGitHub {
    owner = "tkashkin";
    repo = "Adwaita-for-Steam";
    rev = "4.4";
    hash = "sha256-wH0z2LZ94j5ErRI40f9IRBJXJ6yuL+NLgjmj9G8odxU=";
  };

  customCss =
    let
      colors = config.hm.lib.stylix.colors;
      inherit (colors) withHashtag;
      rgba = name: alpha: "rgba(${colors."${name}-rgb-r"}, ${colors."${name}-rgb-g"}, ${colors."${name}-rgb-b"}, ${alpha})";
    in
    with withHashtag;
    pkgs.writeText "adwaita-for-steam-stylix.css" ''
      :root
      {
        --adw-accent-bg-light: ${base0D} !important;
        --adw-accent-bg-dark: ${base0D} !important;

        --adw-destructive-bg-light: ${base08} !important;
        --adw-destructive-bg-dark: ${base08} !important;
        --adw-destructive-fg: ${base00} !important;

        --adw-success-bg-light: ${base0B} !important;
        --adw-success-bg-dark: ${base0B} !important;
        --adw-success-fg: ${base00} !important;

        --adw-warning-bg-light: ${base0E} !important;
        --adw-warning-bg-dark: ${base0E} !important;
        --adw-warning-fg: ${rgba "base00" "0.8"} !important;

        --adw-error-bg-light: ${base08} !important;
        --adw-error-bg-dark: ${base08} !important;
        --adw-error-fg: ${base00} !important;

        --adw-window-bg: ${base00} !important;
        --adw-window-fg: ${base05} !important;

        --adw-view-bg: ${base00} !important;
        --adw-view-fg: ${base05} !important;

        --adw-headerbar-bg: ${base01} !important;
        --adw-headerbar-fg: ${base05} !important;
        --adw-headerbar-border: ${base01} !important;
        --adw-headerbar-backdrop: ${base00} !important;
        --adw-headerbar-shade: rgba(0, 0, 0, 0.9) !important;

        --adw-sidebar-bg: ${base01} !important;
        --adw-sidebar-fg: ${base05} !important;
        --adw-sidebar-backdrop: ${base00} !important;
        --adw-sidebar-shade: rgba(0, 0, 0, 0.36) !important;

        --adw-secondary-sidebar-bg: ${base01} !important;
        --adw-secondary-sidebar-fg: ${base05} !important;
        --adw-secondary-sidebar-backdrop: ${base00} !important;
        --adw-secondary-sidebar-shade: rgba(0, 0, 0, 0.36) !important;

        --adw-card-bg: rgba(0, 0, 0, 0.08) !important;
        --adw-card-fg: ${base05} !important;
        --adw-card-shade: rgba(0, 0, 0, 0.36) !important;

        --adw-dialog-bg: ${base01} !important;
        --adw-dialog-fg: ${base05} !important;

        --adw-popover-bg: ${base01} !important;
        --adw-popover-fg: ${base05} !important;
        --adw-popover-shade: ${rgba "base01" "0.36"} !important;

        --adw-thumbnail-bg: ${base00} !important;
        --adw-thumbnail-fg: ${base05} !important;

        --adw-shade: rgba(0, 0, 0, 0.36) !important;
      }
    '';

  steamRestyle = pkgs.writeShellScriptBin "steam-restyle" ''
    set -u
    if [ ! -x /run/current-system/sw/bin/steam ] \
      && [ ! -d /var/lib/flatpak/app/com.valvesoftware.Steam ] \
      && [ ! -d "$HOME/.local/share/flatpak/app/com.valvesoftware.Steam" ]; then
      echo "Steam is not installed; nothing to theme." >&2
      exit 0
    fi

    if [ ! -d "$HOME/.steam/steam/steamui" ] \
      && [ ! -d "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam/steamui" ]; then
      echo "Steam has not unpacked its UI yet; nothing to theme." >&2
      exit 0
    fi

    # The installer copies its own tree with modes intact, so running it from the store leaves a skin the next run cannot replace.
    work=$(${pkgs.coreutils}/bin/mktemp -d)
    trap '${pkgs.coreutils}/bin/rm -rf "$work"' EXIT
    ${pkgs.coreutils}/bin/cp -r --no-preserve=mode ${adwaitaForSteam} "$work/adwaita-for-steam"

    # The installer exits 0 when a target fails, so its own error line counts as failure too.
    # Window controls are pinned because auto detection reads XDG_CURRENT_DESKTOP, which the activation service lacks, and falls back to close only.
    if out=$(cd "$work/adwaita-for-steam" \
        && ${pkgs.coreutils}/bin/timeout 60s ${lib.getExe pkgs.python3} install.py \
          --custom-css ${customCss} \
          --windowcontrols-theme adwaita \
          --windowcontrols-layout ':minimize,maximize,close' 2>&1) \
      && ! printf '%s' "$out" | ${pkgs.gnugrep}/bin/grep -qE 'Failed to install|Traceback'; then
      echo "Steam theme reapplied. Restart Steam to see it."
    else
      printf '%s\n' "$out" >&2
      echo "steam-restyle: theme apply failed" >&2
      exit 1
    fi
  '';
in
{
  config = lib.mkIf stylixEnabled {
    hm.home.packages = [ steamRestyle ];

    hm.home.activation.updateSteamTheme =
      config.hm.lib.dag.entryAfter [ "writeBoundary" ] ''
        run ${steamRestyle}/bin/steam-restyle
      '';
  };
}
