{ pkgs, lib, config, ... }:

let
  cfg = config.my.desktop.plasma6;
  spectacleOcrLanguages = lib.unique ([ "eng" ] ++ cfg.extraSpectacleOcrLanguages);

  # The numbers Spectacle stores for its formats.
  videoFormats = {
    webm = 1;
    mp4 = 2;
    webp = 4;
    gif = 8;
  };

  spectacle = pkgs.callPackage ./_spectacle.nix {
    tesseractLanguages = spectacleOcrLanguages;
    recording = cfg.spectacleVideoQuality != null;
  };
in
{
  options.my.desktop.plasma6 = {
    enable = lib.mkEnableOption "Plasma 6 desktop environment";

    extraSpectacleOcrLanguages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Tesseract language codes to include in Spectacle OCR. English is always included.";
    };

    spectacleVideoFormat = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (lib.attrNames videoFormats));
      default = null;
      description = "Format of Spectacle's screen recordings. Null leaves the choice to Spectacle's settings.";
    };

    spectacleVideoQuality = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 100);
      default = null;
      description = "Encoding quality of Spectacle's screen recordings, from 0 to 100. Null leaves Spectacle unpatched: each encoder at its default, and a third of the frames dropped.";
    };

    spectacleVideoRegionScale = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 2 4);
      default = null;
      description = "Factor a recorded region is enlarged by while the result stays within 3840x2160. Video stores colour at half the resolution, which shows on a small region. Needs spectacleVideoQuality.";
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
      spectacle
      kdiff3
      wayland-utils
      wl-clipboard
    ];

    # Plasma turns this on by default, and Akonadi then rebuilds its MariaDB database on every login because the home is not persisted.
    programs.kde-pim.enable = false;

    environment.plasma6.excludePackages = with pkgs; [
      kdePackages.elisa
      kdePackages.kmahjongg
      kdePackages.kmines
      kdePackages.konversation
      kdePackages.kpat
      kdePackages.spectacle
      kdePackages.ksudoku
      kdePackages.ktorrent
      mpv
    ];

    assertions = [
      {
        assertion = cfg.spectacleVideoRegionScale == null || cfg.spectacleVideoQuality != null;
        message = "my.desktop.plasma6.spectacleVideoRegionScale needs spectacleVideoQuality, which is what patches Spectacle.";
      }
    ];

    warnings = lib.optional (cfg.spectacleVideoQuality != null && !spectacle.recordingChecked) "Spectacle ${spectacle.version} has not been checked with the recording patches, last checked with ${spectacle.recordingLastChecked}. Each is used only if it still fits, so recordings may be back at Spectacle's default quality or drop frames. Run modules/desktop/plasma/_tests/spectacle-recording.nix and add the release to modules/desktop/plasma/_spectacle.nix.";

    hm.programs.plasma.configFile.spectaclerc = {
      General.ocrLanguages = lib.concatStringsSep "," spectacleOcrLanguages;
      VideoSave = lib.filterAttrs (_: value: value != null) {
        preferredVideoFormat = lib.mapNullable (format: videoFormats.${format}) cfg.spectacleVideoFormat;
        videoQuality = cfg.spectacleVideoQuality;
        videoRegionScale = cfg.spectacleVideoRegionScale;
      };
    };

    services.xserver.excludePackages = [ pkgs.xterm ];
  };
}
