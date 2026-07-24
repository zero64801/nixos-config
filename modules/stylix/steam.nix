{ config, lib, pkgs, ... }:

let
  stylixEnabled = config.nyx.stylix.enable;

  /*
  Steam updates re-extract steamui/ and wipe the injected CSS, so the theme
  needs reapplying (`steam-restyle`, then restart Steam). Steam presence is
  detected at run time, not from nix options, so it works no matter how Steam
  was installed. Installation paths, not data dirs: app data (~/.var,
  persisted here) outlives an uninstall, while the deploy dir under
  flatpak/app only exists while installed.
  */
  steamRestyle = pkgs.writeShellScriptBin "steam-restyle" ''
    set -u
    if [ ! -x /run/current-system/sw/bin/steam ] \
      && [ ! -d /var/lib/flatpak/app/com.valvesoftware.Steam ] \
      && [ ! -d "$HOME/.local/share/flatpak/app/com.valvesoftware.Steam" ]; then
      echo "Steam is not installed; nothing to theme." >&2
      exit 0
    fi

    # adwsteamgtk copies our custom.css with shutil.copy, which stamps the
    # read-only mode of the home-manager store symlink onto its own cache; a
    # re-run then cannot overwrite that cache file. Make it writable first.
    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/AdwSteamInstaller/extracted"
    [ -d "$cache" ] && ${pkgs.coreutils}/bin/chmod -R u+w "$cache" 2>/dev/null || true

    # adwsteamgtk exits 0 even when custom_css.install raises, so treat a
    # Traceback in its output as failure rather than reporting a false success.
    if out=$(${pkgs.coreutils}/bin/timeout 60s ${lib.getExe pkgs.adwsteamgtk} -i 2>&1) \
      && ! printf '%s' "$out" | ${pkgs.gnugrep}/bin/grep -q Traceback; then
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
      config.hm.lib.dag.entryAfter [ "writeBoundary" "dconfSettings" ] ''
        run ${steamRestyle}/bin/steam-restyle
      '';

    hm.dconf.settings."io/github/Foldex/AdwSteamGtk".prefs-install-custom-css = true;

    hm.xdg.configFile."AdwSteamGtk/custom.css".text =
      let
        colors = config.hm.lib.stylix.colors;
      in
      with colors;
      ''
        :root
        {
          --adw-accent-bg-rgb: ${base0D-rgb-r}, ${base0D-rgb-g}, ${base0D-rgb-b};
          --adw-accent-fg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-accent-rgb: ${base0D-rgb-r}, ${base0D-rgb-g}, ${base0D-rgb-b};

          --adw-destructive-bg-rgb: ${base08-rgb-r}, ${base08-rgb-g}, ${base08-rgb-b};
          --adw-destructive-fg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-destructive-rgb: ${base08-rgb-r}, ${base08-rgb-g}, ${base08-rgb-b};

          --adw-success-bg-rgb: ${base0B-rgb-r}, ${base0B-rgb-g}, ${base0B-rgb-b};
          --adw-success-fg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-success-rgb: ${base0B-rgb-r}, ${base0B-rgb-g}, ${base0B-rgb-b};

          --adw-warning-bg-rgb: ${base0E-rgb-r}, ${base0E-rgb-g}, ${base0E-rgb-b};
          --adw-warning-fg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-warning-fg-a: 0.8;
          --adw-warning-rgb: ${base0E-rgb-r}, ${base0E-rgb-g}, ${base0E-rgb-b};

          --adw-error-bg-rgb: ${base08-rgb-r}, ${base08-rgb-g}, ${base08-rgb-b};
          --adw-error-fg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-error-rgb: ${base08-rgb-r}, ${base08-rgb-g}, ${base08-rgb-b};

          --adw-window-bg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-window-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};

          --adw-view-bg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-view-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};

          --adw-headerbar-bg-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-headerbar-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};
          --adw-headerbar-border-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-headerbar-backdrop-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-headerbar-shade-rgb: 0, 0, 0;
          --adw-headerbar-shade-a: 0.9;

          --adw-sidebar-bg-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-sidebar-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};
          --adw-sidebar-backdrop-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-sidebar-shade-rgb: 0, 0, 0;
          --adw-sidebar-shade-a: 0.36;

          --adw-secondary-sidebar-bg-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-secondary-sidebar-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};
          --adw-secondary-sidebar-backdrop-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-secondary-sidebar-shade-rgb: 0, 0, 0;
          --adw-secondary-sidebar-shade-a: 0.36;

          --adw-card-bg-rgb: 0, 0, 0;
          --adw-card-bg-a: 0.08;
          --adw-card-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};
          --adw-card-shade-rgb: 0, 0, 0;
          --adw-card-shade-a: 0.36;

          --adw-dialog-bg-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-dialog-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};

          --adw-popover-bg-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-popover-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};
          --adw-popover-shade-rgb: ${base01-rgb-r}, ${base01-rgb-g}, ${base01-rgb-b};
          --adw-popover-shade-a: 0.36;

          --adw-thumbnail-bg-rgb: ${base00-rgb-r}, ${base00-rgb-g}, ${base00-rgb-b};
          --adw-thumbnail-fg-rgb: ${base05-rgb-r}, ${base05-rgb-g}, ${base05-rgb-b};

          --adw-shade-rgb: 0, 0, 0;
          --adw-shade-a: 0.36;
        }
      '';
  };
}
