{ config, lib, options, ... }:

let
  user = config.nyx.flake.user;
  inherit (lib) mkOption types mkIf;
  # Use the system persistence path or default
  persistentPath = config.nyx.impermanence.persistentStoragePath or "/persist/local";
in
{
  options.nyx.home.persistence = {
    directories = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of directories to persist (relative to HOME)";
    };
    files = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of files to persist (relative to HOME)";
    };
  };

  config = mkIf (config.nyx.home.persistence.directories != [] || config.nyx.home.persistence.files != []) {
    home-manager.users.${user}.home.persistence.${persistentPath} = {
      inherit (config.nyx.home.persistence) directories files;
    };
  };
}
