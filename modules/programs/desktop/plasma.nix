{
  pkgs,
  lib,
  config,
  ...
}:
{
  options.nyx.desktop.plasma6.enable = lib.mkEnableOption "PLASMA6 desktop environment";
  config = lib.mkIf config.nyx.desktop.plasma6.enable {
    services = {
      displayManager.sddm.enable = true;
      desktopManager.plasma6.enable = true;
    };

    environment.systemPackages = with pkgs; [
      # KDE
      kdePackages.discover
      kdePackages.kcalc
      kdePackages.kcharselect
      kdePackages.kclock
      kdePackages.kcolorchooser
      kdePackages.kolourpaint
      kdePackages.ksystemlog
      kdePackages.sddm-kcm
      kdiff3
      # Non-KDE graphical packages
      wayland-utils # Wayland utilities
      wl-clipboard # Command-line copy/paste utilities for Wayland
    ];

    #
    # KDE Exclusions
    #
    environment.plasma6.excludePackages = with pkgs; [
      kdePackages.elisa # Simple music player aiming to provide a nice experience for its users
      kdePackages.kdepim-runtime # Akonadi agents and resources
      kdePackages.kmahjongg # KMahjongg is a tile matching game for one or two players
      kdePackages.kmines # KMines is the classic Minesweeper game
      kdePackages.konversation # User-friendly and fully-featured IRC client
      kdePackages.kpat # KPatience offers a selection of solitaire card games
      kdePackages.ksudoku # KSudoku is a logic-based symbol placement puzzle
      kdePackages.ktorrent # Powerful BitTorrent client
      mpv
    ];

    services.xserver.excludePackages = [ pkgs.xterm ];
  };
}
