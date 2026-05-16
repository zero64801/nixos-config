{ pkgs, lib, config, ... }:

let
  cfg = config.nyx.desktop.plasma6;
  spectacleOcrLanguages = lib.unique ([ "eng" ] ++ cfg.extraSpectacleOcrLanguages);
  spectacleWithOcr = pkgs.kdePackages.spectacle.override {
    tesseractLanguages = spectacleOcrLanguages;
  };
in
{
  options.nyx.desktop.plasma6 = {
    enable = lib.mkEnableOption "Plasma 6 desktop environment";

    extraSpectacleOcrLanguages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Tesseract language codes to include in Spectacle OCR. English is always included.";
    };
  };

  config = lib.mkIf cfg.enable {
    services = {
      displayManager.sddm.enable = true;
      desktopManager.plasma6.enable = true;
    };

    environment.systemPackages = with pkgs; [
      kdePackages.discover
      kdePackages.kcalc
      kdePackages.kcharselect
      kdePackages.kclock
      kdePackages.kcolorchooser
      kdePackages.kolourpaint
      kdePackages.ksystemlog
      kdePackages.sddm-kcm
      spectacleWithOcr
      kdiff3
      wayland-utils
      wl-clipboard
    ];

    environment.plasma6.excludePackages = with pkgs; [
      kdePackages.elisa
      kdePackages.kdepim-runtime
      kdePackages.kmahjongg
      kdePackages.kmines
      kdePackages.konversation
      kdePackages.kpat
      kdePackages.spectacle
      kdePackages.ksudoku
      kdePackages.ktorrent
      mpv
    ];

    hm.programs.plasma.configFile.spectaclerc.General.ocrLanguages = lib.concatStringsSep "," spectacleOcrLanguages;

    services.xserver.excludePackages = [ pkgs.xterm ];
  };
}
