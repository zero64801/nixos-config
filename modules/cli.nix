{ config, lib, ... }:

let
  cfg = config.my.cli;
in
{
  options.my.cli.enable = lib.mkEnableOption "nh as the rebuild and garbage collection front end";

  config = lib.mkIf cfg.enable {
    programs.nh = {
      enable = true;
      flake = config.my.flakePath;

      # nix.gc's --delete-older-than keeps no fixed count, so a week without switching leaves nothing to roll back to.
      # Result links stay because some are live references, such as an MCP server registered by its result path.
      clean = {
        enable = true;
        extraArgs = "--keep 5 --keep-since 7d --no-gcroots";
      };
    };

    nix.gc.automatic = false;
  };
}
