{
  lib,
  config,
  pkgs,
  ...
}: {
  options.nyx.programs.zeditor.enable = lib.mkEnableOption "zeditor";
  config = lib.mkIf config.nyx.programs.zeditor.enable {
    home-manager.users = lib.genAttrs config.nyx.data.users (username: {
      programs.zed-editor = {
        enable = true;
      };
    });
  };
}
