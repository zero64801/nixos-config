{ config, lib, ... }:

let
  cfg = config.nyx.apps.zeditor;
in
{
  options.nyx.apps.zeditor.enable = lib.mkEnableOption "Zed editor";

  config = lib.mkIf cfg.enable {
    hm.programs.zed-editor = {
      enable = true;
      extensions = [ "nix" "lua" ];
    };
  };
}
