{ config, lib, ... }:

let
  cfg = config.nyx.apps.git;
in
{
  options.nyx.apps.git = {
    enable = lib.mkEnableOption "Git version control";

    email = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Email address for Git commits";
    };
  };

  config = lib.mkIf cfg.enable {
    hm.programs.git = {
      enable = true;

      settings = {
        user = {
          name = config.nyx.flake.user;
          email = cfg.email;
        };
        safe.directory = "~/nixos";
        init.defaultBranch = "main";
        pull.rebase = false;
      };
    };
  };
}
