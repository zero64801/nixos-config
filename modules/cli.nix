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
    };
  };
}
