{ pkgs, ... }:

{
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        opacity = 0.85;
        padding = { x = 10; y = 10; };
        decorations = "none";
      };

      font = {
        normal = {
          family = "CaskaydiaMono NF";
          style = "Regular";
        };
        bold = {
          family = "CaskaydiaMono NF";
          style = "Bold";
        };
        italic = {
          family = "CaskaydiaMono NF";
          style = "Italic";
        };
        size = 10;
      };

      colors = {
        primary = {
          background = "0x1e1e2e";
          foreground = "0xcdd6f4";
        };
        cursor = {
          text = "0x1e1e2e";
          cursor = "0xf5c2e7";
        };
        selection = {
          text = "0x1e1e2e";
          background = "0xcba6f7";
        };
        normal = {
          black = "0x45475a";
          red = "0xf38ba8";
          green = "0xa6e3a1";
          yellow = "0xf9e2af";
          blue = "0x89b4fa";
          magenta = "0xf5c2e7";
          cyan = "0x89dceb";
          white = "0xbac2de";
        };
        bright = {
          black = "0x585b70";
          red = "0xf38ba8";
          green = "0xa6e3a1";
          yellow = "0xf9e2af";
          blue = "0x89b4fa";
          magenta = "0xf5c2e7";
          cyan = "0x89dceb";
          white = "0xa6adc8";
        };
      };
    };
  };
}
