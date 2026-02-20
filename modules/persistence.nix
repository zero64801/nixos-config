{ config, lib, ... }:

let
  inherit (lib) mkOption mkIf types;

  cfg  = config.nyx.persistence;
  user = config.nyx.flake.user;
  persistentPath = config.nyx.impermanence.persistentStoragePath or "/persist/local";

  hasHomeEntries = cfg.home.directories != [] || cfg.home.files != [];
in
{
  options.nyx.persistence = {
    directories = mkOption {
      type    = types.listOf (types.either types.str (types.attrsOf types.anything));
      default = [];
      description = "System directories to persist (absolute paths or attrsets with directory/user/group/mode).";
    };

    files = mkOption {
      type    = types.listOf types.str;
      default = [];
      description = "System files to persist (absolute paths).";
    };

    home = {
      directories = mkOption {
        type    = types.listOf types.str;
        default = [];
        description = "User home directories to persist (relative to HOME).";
      };

      files = mkOption {
        type    = types.listOf types.str;
        default = [];
        description = "User home files to persist (relative to HOME).";
      };
    };
  };

  config = mkIf (config.nyx.impermanence.enable or false) {
    environment.persistence.${persistentPath} = {
      # Empty lists are fine — no need to guard with mkIf.
      directories = cfg.directories;
      files       = cfg.files;

      users.${user} = mkIf hasHomeEntries {
        inherit (cfg.home) directories files;
      };
    };
  };
}
