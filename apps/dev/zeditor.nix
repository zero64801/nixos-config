{ config, lib, ... }:

let
  cfg = config.nyx.apps.zeditor;
in
{
  options.nyx.apps.zeditor = {
    enable = lib.mkEnableOption "Zed editor";
    context_servers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
  };

  config = lib.mkIf cfg.enable {
    hm.programs.zed-editor = {
      enable = true;
      extensions = [ "nix" "lua" "copilot" ];
      userSettings = {
        features = {
          copilot = true;
        };
        context_servers = cfg.context_servers;
      };
    };
  };
}
