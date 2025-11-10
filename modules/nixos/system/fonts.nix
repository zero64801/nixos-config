{ pkgs, config, lib, ... }:

{
  config = lib.mkIf (!config.nyx.data.headless) {
    fonts = {
      fontDir.enable = lib.mkDefault true;

      packages = with pkgs; [
        nerd-fonts.caskaydia-mono
        nerd-fonts.caskaydia-cove
        noto-fonts
        noto-fonts-color-emoji
        noto-fonts-cjk-sans
        noto-fonts-cjk-serif
        material-symbols
      ];

      fontconfig = {
        defaultFonts = {
          serif = lib.mkDefault [ "Noto Serif" ];
          sansSerif = lib.mkDefault [ "Noto Sans" ];
          monospace = lib.mkDefault [ "CaskaydiaCove Nerd Font Mono" ];
          emoji = lib.mkDefault [ "Noto Color Emoji" ];
        };
      };
    };
  };
}
