{
  pkgs,
  config,
  lib,
  ...
}:
let
  inherit (lib) mkIf attrValues;
in
{
  config = mkIf (!config.nyx.data.headless) {
    fonts = {
      fontDir.enable = true;
      packages = attrValues {
        inherit (pkgs.nerd-fonts) caskaydia-mono caskaydia-cove;
        inherit (pkgs) noto-fonts noto-fonts-color-emoji noto-fonts-cjk-sans;
        inherit (pkgs) noto-fonts-cjk-serif material-symbols;
      };
    };
  };
}
