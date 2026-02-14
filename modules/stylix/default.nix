{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.nyx.stylix;
  schemes = (pkgs.util.importFlake ./sources).inputs.schemes;
in
{
  imports = [
    inputs.stylix.nixosModules.stylix
  ];

  options.nyx.stylix = {
    enable = lib.mkEnableOption "Stylix theming with nyx management";

    scheme = lib.mkOption {
      type = lib.types.str;
      default = "ayu-dark";
      description = "Base16 color scheme name (from tinted-theming/schemes)";
    };

    polarity = lib.mkOption {
      type = lib.types.enum [ "dark" "light" "either" ];
      default = "dark";
      description = "Color scheme polarity";
    };

    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Wallpaper image path";
    };

    icons = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable icon theming";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.papirus-icon-theme;
        description = "Icon theme package";
      };

      dark = lib.mkOption {
        type = lib.types.str;
        default = "Papirus-Dark";
        description = "Dark icon theme name";
      };

      light = lib.mkOption {
        type = lib.types.str;
        default = "Papirus-Light";
        description = "Light icon theme name";
      };
    };

    cursor = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bibata-cursors;
        description = "Cursor theme package";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "Bibata-Modern-Ice";
        description = "Cursor theme name";
      };

      size = lib.mkOption {
        type = lib.types.int;
        default = 24;
        description = "Cursor size in pixels";
      };
    };

    fonts = {
      sansSerif = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.noto-fonts;
          description = "Sans-serif font package";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "Noto Sans";
        };
      };

      monospace = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.nerd-fonts.jetbrains-mono;
          description = "Monospace font package";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "JetBrainsMono Nerd Font";
        };
      };

      serif = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.noto-fonts;
          description = "Serif font package";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "Noto Serif";
        };
      };

      emoji = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.noto-fonts-color-emoji;
          description = "Emoji font package";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "Noto Color Emoji";
        };
      };

      sizes = {
        applications = lib.mkOption {
          type = lib.types.int;
          default = 12;
          description = "Font size for applications";
        };
        desktop = lib.mkOption {
          type = lib.types.int;
          default = 10;
          description = "Font size for desktop elements";
        };
        popups = lib.mkOption {
          type = lib.types.int;
          default = 10;
          description = "Font size for popups and tooltips";
        };
        terminal = lib.mkOption {
          type = lib.types.int;
          default = 12;
          description = "Font size for terminal";
        };
      };
    };

    targets = {
      gtk.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable GTK theming";
      };
      qt.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Qt theming";
      };
      fontconfig.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable fontconfig theming";
      };
    };

    opacity = {
      terminal = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Terminal opacity (0.0 - 1.0)";
      };
      desktop = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Desktop element opacity (0.0 - 1.0)";
      };
      applications = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Application opacity (0.0 - 1.0)";
      };
      popups = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Popup opacity (0.0 - 1.0)";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    stylix = {
      enable = true;
      base16Scheme = "${schemes}/base16/${cfg.scheme}.yaml";
      polarity = cfg.polarity;

      image = lib.mkIf (cfg.wallpaper != null) cfg.wallpaper;

      icons = lib.mkIf cfg.icons.enable {
        enable = true;
        inherit (cfg.icons) package dark light;
      };

      cursor = {
        inherit (cfg.cursor) package name size;
      };

      targets = {
        gtk.enable = cfg.targets.gtk.enable;
        qt.enable = cfg.targets.qt.enable;
        fontconfig.enable = cfg.targets.fontconfig.enable;
      };

      fonts = {
        sansSerif = {
          inherit (cfg.fonts.sansSerif) package name;
        };
        monospace = {
          inherit (cfg.fonts.monospace) package name;
        };
        serif = {
          inherit (cfg.fonts.serif) package name;
        };
        emoji = {
          inherit (cfg.fonts.emoji) package name;
        };
        sizes = {
          inherit (cfg.fonts.sizes) applications desktop popups terminal;
        };
      };

      opacity = {
        inherit (cfg.opacity) terminal desktop applications popups;
      };
    };
  };
}
