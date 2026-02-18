{ pkgs, lib, config, ... }:

let
  cfg = config.nyx.desktop.plasma6;
in
{
  options.nyx.desktop.plasma6.enable = lib.mkEnableOption "Plasma 6 desktop environment";

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
      kdePackages.ksudoku
      kdePackages.ktorrent
      mpv
    ];

    services.xserver.excludePackages = [ pkgs.xterm ];
  };
}
