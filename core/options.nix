{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption;
  inherit (lib.types) str listOf;
in
{
  options.nyx = {
    desktop.enable = mkEnableOption "desktop environment (disables GUI components when false)";

    flake = {
      host = mkOption {
        description = "Hostname of the system";
        type = str;
        default = "Quanta";
      };

      user = mkOption {
        description = "The primary user of the system";
        type = str;
        default = "dx";
      };
    };

    security.serviceAdminGroups = mkOption {
      type = listOf str;
      default = [];
      description = ''
        A list of groups that grant administrative access to system services.
        Service modules can add their group to this list.
      '';
    };
  };
}
