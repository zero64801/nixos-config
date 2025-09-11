{ lib, pkgs, config, ... }:
let
  inherit (lib) mkOption mkIf mapAttrsToList literalExpression;
  inherit (lib.types) attrs attrsOf str bool listOf;
  inherit (pkgs.writeText) writeText;
  inherit (builtins) toJSON;

  cfg = config.nyx.desktop.dconf;
  usersConfig = config.nyx.users;

  # Convert nix values to dconf INI format
  toDconfValue = value:
    if builtins.isBool value then lib.boolToString value
    else if builtins.isString value then "'${value}'"
    else if builtins.isInt value then toString value
    else if builtins.isList value then
      let formattedItems = map (item: "'${item}'") value;
      in "[${lib.concatStringsSep ", " formattedItems}]"
    else toString value;

  mkIniKeyValue = key: value: "${key}=${toDconfValue value}";
  toDconfIni = lib.generators.toINI { inherit mkIniKeyValue; };

  # Generate dconf settings for a specific user
  generateUserDconf = userName: userConfig:
    let
      settings = userConfig.dconf.settings or {};
      iniContent = toDconfIni settings;
      
      # List of all keys being managed
      managedKeys = lib.concatLists (
        lib.mapAttrsToList (
          dir: entries: lib.mapAttrsToList (key: _: "/${dir}/${key}") entries
        ) settings
      );
      
      keysFile = writeText "dconf-keys-${userName}.json" (toJSON managedKeys);
    in
    mkIf (settings != {}) {
      # Add the files to the user's hjem configuration
      hjem.users.${userName}.xdg.data.files = {
        "dconf/settings.ini".text = iniContent;
        "dconf/managed-keys.json".source = keysFile;
      };
      
      # Create activation script
      hjem.users.${userName}.files.".local/share/hjem/activate.d/dconf".text = ''
        #!/bin/sh
        set -e
        
        if [ -n "$DCONF_SESSION_BUS_ADDRESS" ]; then
          export DCONF_DBUS_RUN_SESSION=""
        else
          export DCONF_DBUS_RUN_SESSION="${pkgs.dbus}/bin/dbus-run-session --dbus-daemon=${pkgs.dbus}/bin/dbus-daemon"
        fi
        
        # Reset unmanaged keys if we have previous state
        if [ -f "$HOME/.local/share/hjem/state/dconf-keys.json" ]; then
          ${pkgs.jq}/bin/jq -r '.[]' "$HOME/.local/share/hjem/state/dconf-keys.json" | \
          while read -r key; do
            if ! ${pkgs.jq}/bin/jq -e --arg key "$key" 'index($key)' "$HOME/.local/share/hjem/data/dconf/managed-keys.json" > /dev/null; then
              echo "Resetting unmanaged dconf key: $key"
              $DCONF_DBUS_RUN_SESSION ${pkgs.dconf}/bin/dconf reset "$key"
            fi
          done
        fi
        
        # Load new settings
        echo "Loading dconf settings..."
        $DCONF_DBUS_RUN_SESSION ${pkgs.dconf}/bin/dconf load / < "$HOME/.local/share/hjem/data/dconf/settings.ini"
        
        # Save current state
        mkdir -p "$HOME/.local/share/hjem/state"
        cp "$HOME/.local/share/hjem/data/dconf/managed-keys.json" "$HOME/.local/share/hjem/state/dconf-keys.json"
        
        unset DCONF_DBUS_RUN_SESSION
      '';
    };

in
{
  options.nyx.desktop.dconf = {
    enable = mkOption {
      type = bool;
      default = true;
      description = "Whether to enable declarative dconf configuration";
    };
    
    settings = mkOption {
      type = attrsOf (attrsOf str);
      default = {};
      description = ''
        Global dconf settings applied to all users.
        These settings can be overridden by per-user configuration.
      '';
      example = literalExpression ''
        {
          "org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            gtk-theme = "Adwaita-dark";
          };
        }
      '';
    };
  };

  # Per-user dconf configuration
  options.nyx.users = mkOption {
    type = attrsOf (lib.types.submodule ({ name, ... }: {
      options.dconf = {
        enable = mkOption {
          type = bool;
          default = cfg.enable;
          description = "Enable dconf configuration for this user";
        };
        
        settings = mkOption {
          type = attrsOf (attrsOf str);
          default = {};
          description = "Dconf settings for this specific user";
        };
      };
    }));
    default = {};
  };

  config = mkIf cfg.enable {
    # Ensure dconf is available system-wide
    environment.systemPackages = [ pkgs.dconf ];
    
    # Generate configuration for each user
    config = lib.mkMerge (
      mapAttrsToList generateUserDconf usersConfig
    );
  };
}
