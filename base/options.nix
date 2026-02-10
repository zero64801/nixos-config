{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption;
  inherit (lib.types) str;
in
{
  options.nyx = {
    data.headless = mkEnableOption "headless mode (disables GUI components)";

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
  };
}
