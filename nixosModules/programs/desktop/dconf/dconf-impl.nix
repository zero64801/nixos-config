{ lib, pkgs, config, ... }:

let
  inherit (lib) mkIf;
  inherit (lib.attrsets) mapAttrs' filterAttrs nameValuePair;

  configuredUsers = filterAttrs (
    name: user: user.enable && user.dconf.settings != {}
  ) config.hjem.users;

  toDconfStringValue = value:
    if builtins.isBool value then lib.boolToString value
    else if builtins.isString value then "'${value}'"
    else if builtins.isInt value then toString value
    else if builtins.isFloat value then toString value
    else if builtins.isList value then
      let formattedItems = map (item: "'${toString item}'") value;
      in "[${lib.concatStringsSep ", " formattedItems}]"
    else builtins.toJSON value;

  toDconfIni = lib.generators.toINI {
    mkKeyValue = key: value: "${key}=${toDconfStringValue value}";
  };

  dconfLoginServices = mapAttrs' (
    userName: userConfig:
      nameValuePair "dconf-load-${userName}" {
        description = "Load dconf settings for ${userName} at login";
        
        # We still use this target for correct timing.
        wantedBy = [ "gnome-session-initialized.target" ];
        partOf = [ "graphical-session.target" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = let
            iniFile = pkgs.writeText "dconf-${userName}.ini" (toDconfIni userConfig.dconf.settings);
            # This is the definitive script that actively sources its own environment.
            script = pkgs.writeShellScript "dconf-loader" ''
              #!${pkgs.bash}/bin/bash
              set -euo pipefail

              # This is the key:
              # 1. Query the user's own systemd manager for its environment block.
              # 2. Use 'eval' to export all those variables (DISPLAY, DBUS_SESSION_BUS_ADDRESS, etc.)
              #    into the current script's environment.
              eval $(${pkgs.systemd}/bin/systemctl --user --no-pager show-environment)

              # Now that the environment is sourced, this check will pass in a graphical session.
              if [[ -z "''${DISPLAY:-}" || -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
                echo "Not a graphical session, skipping dconf load."
                exit 0
              fi

              echo "Applying dconf settings for ${userName}."
              ${pkgs.dconf}/bin/dconf load / < ${iniFile}
            '';
          in "${script}";
        };
      }
  ) configuredUsers;
in
{
  config = mkIf (configuredUsers != {}) {
    programs.dconf.enable = true;
    systemd.user.services = dconfLoginServices;
  };
}
