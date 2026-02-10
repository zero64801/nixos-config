{ pkgs, config, lib, ... }:

{
  config = lib.mkIf (!config.nyx.data.headless) {
    hm.gtk = {
      enable = true;

      theme = {
        name = "Orchis-Dark-Compact";
        package = pkgs.orchis-theme;
      };

      iconTheme = {
        name = "Tela-dark";
        package = pkgs.tela-icon-theme;
      };
    };
  };
}
