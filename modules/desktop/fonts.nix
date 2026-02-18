{ pkgs, config, lib, ... }:

{
  config = lib.mkIf config.nyx.desktop.enable {
    fonts = {
      fontDir.enable = lib.mkDefault true;

      packages = with pkgs; [
        noto-fonts-cjk-sans
        noto-fonts-cjk-serif
        material-symbols
      ];
    };
  };
}
