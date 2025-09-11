{
  lib,
  config,
  pkgs,
  ...
}: {
  options.nyx.programs.helix.enable = lib.mkEnableOption "helix";
  config = lib.mkIf config.nyx.programs.helix.enable {
    home-manager.users = lib.genAttrs config.nyx.data.users (username: {
      programs.helix = {
        enable = true;

        settings = {
          theme = "catppuccin_macchiato_transparent";
          editor = {
            line-number = "relative";
            lsp = {
              display-messages = true;
              display-inlay-hints = true;
            };
            indent-guides.render = true;
          };
        };

        themes.catppuccin_macchiato_transparent = {
          inherits = "catppuccin_macchiato";
          "ui.background" = { };
        };
      };
    });
  };
}
