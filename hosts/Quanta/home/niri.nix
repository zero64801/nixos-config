{ config, lib, pkgs, ... }:

let
  stylixEnabled = config.nyx.stylix.enable or false;
  fallbackPalette = rec {
    base00 = "191724";
    base01 = "1f1d2e";
    base02 = "26233a";
    base03 = "6e6a86";
    base04 = "908caa";
    base05 = "e0def4";
    base08 = "eb6f92";
    base09 = "f6c177";
    base0B = "31748f";
    base0C = "9ccfd8";
    base0D = "c4a7e7";
    base0E = "f6c177";

    "base00-rgb-r" = "25";
    "base00-rgb-g" = "23";
    "base00-rgb-b" = "36";
    "base01-rgb-r" = "31";
    "base01-rgb-g" = "29";
    "base01-rgb-b" = "46";
    "base02-rgb-r" = "38";
    "base02-rgb-g" = "35";
    "base02-rgb-b" = "58";
    "base03-rgb-r" = "110";
    "base03-rgb-g" = "106";
    "base03-rgb-b" = "134";
    "base04-rgb-r" = "144";
    "base04-rgb-g" = "140";
    "base04-rgb-b" = "170";
    "base05-rgb-r" = "224";
    "base05-rgb-g" = "222";
    "base05-rgb-b" = "244";
    "base08-rgb-r" = "235";
    "base08-rgb-g" = "111";
    "base08-rgb-b" = "146";
    "base09-rgb-r" = "246";
    "base09-rgb-g" = "193";
    "base09-rgb-b" = "119";
    "base0B-rgb-r" = "49";
    "base0B-rgb-g" = "116";
    "base0B-rgb-b" = "143";
    "base0D-rgb-r" = "196";
    "base0D-rgb-g" = "167";
    "base0D-rgb-b" = "231";
    "base0E-rgb-r" = "246";
    "base0E-rgb-g" = "193";
    "base0E-rgb-b" = "119";

    withHashtag = {
      base00 = "#${base00}";
      base01 = "#${base01}";
      base02 = "#${base02}";
      base03 = "#${base03}";
      base04 = "#${base04}";
      base05 = "#${base05}";
      base08 = "#${base08}";
      base09 = "#${base09}";
      base0B = "#${base0B}";
      base0C = "#${base0C}";
      base0D = "#${base0D}";
      base0E = "#${base0E}";
    };
  };
  palette =
    if stylixEnabled
    then config.stylix.base16.mkSchemeAttrs config.stylix.base16Scheme
    else fallbackPalette;
  colors = palette.withHashtag;
  qtRgb = name: "${palette."${name}-rgb-r"},${palette."${name}-rgb-g"},${palette."${name}-rgb-b"}";
  monospaceFont =
    if stylixEnabled
    then config.stylix.fonts.monospace.name
    else "JetBrainsMono Nerd Font";
  sansFont =
    if stylixEnabled
    then config.stylix.fonts.sansSerif.name
    else "Noto Sans";
  cursorTheme =
    if stylixEnabled && (config.nyx.stylix.cursor.enable or false)
    then config.nyx.stylix.cursor.name
    else "Adwaita";
  cursorPackage =
    if stylixEnabled && (config.nyx.stylix.cursor.enable or false)
    then config.nyx.stylix.cursor.package
    else pkgs.adwaita-icon-theme;
  stylixIconsEnabled = stylixEnabled && (config.nyx.stylix.icons.enable or false);
  iconTheme =
    if stylixIconsEnabled
    then
      if (config.nyx.stylix.polarity or "dark") == "light"
      then config.nyx.stylix.icons.light
      else config.nyx.stylix.icons.dark
    else "Tela-purple-dark";
  iconPackage =
    if stylixIconsEnabled
    then config.nyx.stylix.icons.package
    else pkgs.tela-icon-theme;
  niriCursorSize = 24;
  videoMimeTypes = [
    "video/mp4"
    "video/x-matroska"
    "video/webm"
    "video/x-msvideo"
    "video/quicktime"
    "video/mpeg"
  ];
  audioMimeTypes = [
    "audio/mpeg"
    "audio/flac"
    "audio/ogg"
    "audio/wav"
    "audio/x-wav"
    "audio/mp4"
    "audio/aac"
    "audio/opus"
  ];
  imageMimeTypes = [
    "image/avif"
    "image/bmp"
    "image/gif"
    "image/heif"
    "image/jpeg"
    "image/jpg"
    "image/jxl"
    "image/png"
    "image/svg+xml"
    "image/tiff"
    "image/webp"
    "image/x-bmp"
    "image/x-exr"
    "image/x-png"
    "image/x-targa"
    "image/x-tga"
  ];
  mediaMimeTypes = videoMimeTypes ++ audioMimeTypes;
  fileManagerDesktopFile = "thunar.desktop";
  imageViewerDesktopFile = "swayimg.desktop";
  mediaPlayerDesktopFile = "mpv.desktop";
  appFontSize =
    if stylixEnabled
    then config.stylix.fonts.sizes.applications
    else 12;
  desktopFontSize =
    if stylixEnabled
    then config.stylix.fonts.sizes.desktop
    else 10;
  fallbackWallpaper = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/Elarun/contents/images/2560x1600.png";
  dmsPrimaryOutput = "DP-1";
  dmsWallpaper =
    if stylixEnabled && (config.nyx.stylix.wallpaper or null) != null
    then config.nyx.stylix.wallpaper
    else fallbackWallpaper;
  dmsSettings = {
    configVersion = 5;
    launcherLogoMode = "os";
    launcherLogoCustomPath = "";
    launcherLogoColorOverride = "";
    launcherLogoColorInvertOnMode = false;
    launcherLogoBrightness = 0.5;
    launcherLogoContrast = 1;
    launcherLogoSizeOffset = 0;
    wallpaperFillMode = "Fill";
    showOccupiedWorkspacesOnly = true;
    screenPreferences = {
      dock = [ dmsPrimaryOutput ];
      notifications = [ dmsPrimaryOutput ];
      notepad = [ dmsPrimaryOutput ];
      osd = [ dmsPrimaryOutput ];
      toast = [ dmsPrimaryOutput ];
    };
    showOnLastDisplay = {
      dock = false;
      notifications = false;
      notepad = false;
      osd = false;
      toast = false;
    };
    barConfigs = [
      {
        id = "default";
        name = "Main Bar";
        enabled = true;
        position = 0;
        screenPreferences = [ dmsPrimaryOutput ];
        showOnLastDisplay = false;
        leftWidgets = [ "launcherButton" "workspaceSwitcher" "focusedWindow" ];
        centerWidgets = [ "music" "clock" "weather" ];
        rightWidgets = [ "systemTray" "clipboard" "cpuUsage" "memUsage" "notificationButton" "battery" "controlCenterButton" ];
        spacing = 4;
        innerPadding = 4;
        bottomGap = 0;
        transparency = 1;
        widgetTransparency = 1;
        squareCorners = false;
        noBackground = false;
        maximizeWidgetIcons = false;
        maximizeWidgetText = false;
        removeWidgetPadding = false;
        widgetPadding = 8;
        gothCornersEnabled = false;
        gothCornerRadiusOverride = false;
        gothCornerRadiusValue = 12;
        borderEnabled = false;
        borderColor = "surfaceText";
        borderOpacity = 1;
        borderThickness = 1;
        widgetOutlineEnabled = false;
        widgetOutlineColor = "primary";
        widgetOutlineOpacity = 1;
        widgetOutlineThickness = 1;
        fontScale = 1;
        iconScale = 1;
        autoHide = false;
        autoHideDelay = 250;
        showOnWindowsOpen = false;
        openOnOverview = false;
        visible = true;
        popupGapsAuto = true;
        popupGapsManual = 4;
        maximizeDetection = true;
        scrollEnabled = true;
        scrollXBehavior = "column";
        scrollYBehavior = "workspace";
        shadowIntensity = 0;
        shadowOpacity = 60;
        shadowColorMode = "text";
        shadowCustomColor = "#000000";
        clickThrough = false;
      }
    ];
  };
  dmsSession = {
    configVersion = 3;
    wallpaperPath = toString dmsWallpaper;
    wallpaperPathLight = toString dmsWallpaper;
    wallpaperPathDark = toString dmsWallpaper;
    perMonitorWallpaper = false;
    monitorWallpapers = {};
    monitorWallpapersLight = {};
    monitorWallpapersDark = {};
    monitorWallpaperFillModes = {};
    perModeWallpaper = false;
    wallpaperTransition = "fade";
    wallpaperCyclingEnabled = false;
  };
  dmsSettingsJson = pkgs.writeText "dms-settings.json" (builtins.toJSON dmsSettings);
  dmsSessionJson = pkgs.writeText "dms-session.json" (builtins.toJSON dmsSession);
  qtColorScheme = ''
    [ColorEffects:Disabled]
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.500000
    ContrastEffect=1
    IntensityAmount=0
    IntensityEffect=0
    [ColorEffects:Inactive]
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.500000
    ContrastEffect=1
    IntensityAmount=0
    IntensityEffect=0
    [Colors:Button]
    BackgroundAlternate=${qtRgb "base01"}
    BackgroundNormal=${qtRgb "base00"}
    DecorationFocus=${qtRgb "base0D"}
    DecorationHover=${qtRgb "base0D"}
    ForegroundActive=${qtRgb "base05"}
    ForegroundInactive=${qtRgb "base05"}
    ForegroundLink=${qtRgb "base0D"}
    ForegroundNegative=${qtRgb "base08"}
    ForegroundNeutral=${qtRgb "base0D"}
    ForegroundNormal=${qtRgb "base05"}
    ForegroundPositive=${qtRgb "base0B"}
    ForegroundVisited=${qtRgb "base0E"}
    [Colors:Complementary]
    BackgroundAlternate=${qtRgb "base01"}
    BackgroundNormal=${qtRgb "base00"}
    DecorationFocus=${qtRgb "base0D"}
    DecorationHover=${qtRgb "base0D"}
    ForegroundActive=${qtRgb "base05"}
    ForegroundInactive=${qtRgb "base05"}
    ForegroundLink=${qtRgb "base0D"}
    ForegroundNegative=${qtRgb "base08"}
    ForegroundNeutral=${qtRgb "base0D"}
    ForegroundNormal=${qtRgb "base05"}
    ForegroundPositive=${qtRgb "base0B"}
    ForegroundVisited=${qtRgb "base0E"}
    [Colors:Selection]
    BackgroundAlternate=${qtRgb "base0D"}
    BackgroundNormal=${qtRgb "base0D"}
    DecorationFocus=${qtRgb "base0D"}
    DecorationHover=${qtRgb "base0D"}
    ForegroundActive=${qtRgb "base00"}
    ForegroundInactive=${qtRgb "base00"}
    ForegroundLink=${qtRgb "base00"}
    ForegroundNegative=${qtRgb "base08"}
    ForegroundNeutral=${qtRgb "base0D"}
    ForegroundNormal=${qtRgb "base00"}
    ForegroundPositive=${qtRgb "base0B"}
    ForegroundVisited=${qtRgb "base00"}
    [Colors:Tooltip]
    BackgroundAlternate=${qtRgb "base01"}
    BackgroundNormal=${qtRgb "base00"}
    DecorationFocus=${qtRgb "base0D"}
    DecorationHover=${qtRgb "base0D"}
    ForegroundActive=${qtRgb "base05"}
    ForegroundInactive=${qtRgb "base05"}
    ForegroundLink=${qtRgb "base0D"}
    ForegroundNegative=${qtRgb "base08"}
    ForegroundNeutral=${qtRgb "base0D"}
    ForegroundNormal=${qtRgb "base05"}
    ForegroundPositive=${qtRgb "base0B"}
    ForegroundVisited=${qtRgb "base0E"}
    [Colors:View]
    BackgroundAlternate=${qtRgb "base01"}
    BackgroundNormal=${qtRgb "base00"}
    DecorationFocus=${qtRgb "base0D"}
    DecorationHover=${qtRgb "base0D"}
    ForegroundActive=${qtRgb "base05"}
    ForegroundInactive=${qtRgb "base05"}
    ForegroundLink=${qtRgb "base0D"}
    ForegroundNegative=${qtRgb "base08"}
    ForegroundNeutral=${qtRgb "base0D"}
    ForegroundNormal=${qtRgb "base05"}
    ForegroundPositive=${qtRgb "base0B"}
    ForegroundVisited=${qtRgb "base0E"}
    [Colors:Window]
    BackgroundAlternate=${qtRgb "base01"}
    BackgroundNormal=${qtRgb "base00"}
    DecorationFocus=${qtRgb "base0D"}
    DecorationHover=${qtRgb "base0D"}
    ForegroundActive=${qtRgb "base05"}
    ForegroundInactive=${qtRgb "base05"}
    ForegroundLink=${qtRgb "base0D"}
    ForegroundNegative=${qtRgb "base08"}
    ForegroundNeutral=${qtRgb "base0D"}
    ForegroundNormal=${qtRgb "base05"}
    ForegroundPositive=${qtRgb "base0B"}
    ForegroundVisited=${qtRgb "base0E"}
    [General]
    ColorScheme=RosPine
    Name=Rose Pine
    [WM]
    activeBackground=${qtRgb "base00"}
    activeBlend=${qtRgb "base0D"}
    activeForeground=${qtRgb "base05"}
    inactiveBackground=${qtRgb "base00"}
    inactiveBlend=${qtRgb "base03"}
    inactiveForeground=${qtRgb "base05"}
  '';

  defaultConfig = builtins.readFile "${pkgs.niri.doc}/share/doc/niri/default-config.kdl";
  quantaConfig = builtins.replaceStrings
    [
      "binds {\n"
      ''active-color "#7fc8ff"''
      ''inactive-color "#505050"''
      ''active-color "#ffc87f"''
      ''urgent-color "#9b0000"''
      ''color "#0007"''
      ''
        // This line starts waybar, a commonly used bar for Wayland compositors.
        spawn-at-startup "waybar"
      ''
      ''Mod+D hotkey-overlay-title="Run an Application: fuzzel" { spawn "fuzzel"; }''
      "    Print { screenshot; }\n"
      "    Ctrl+Print { screenshot-screen; }\n"
      "    Alt+Print { screenshot-window; }\n"
    ]
    [
      ''
        binds {
            Mod+E { spawn "thunar"; }
            Mod+G hotkey-overlay-title="Open Looking Glass" { spawn "${pkgs.looking-glass-client}/bin/looking-glass-client"; }
            Mod+Shift+G hotkey-overlay-title="Open Looking Glass fullscreen" { spawn "${pkgs.looking-glass-client}/bin/looking-glass-client" "-F"; }
            Mod+Shift+M hotkey-overlay-title="Open music player: kew" { spawn "alacritty" "-e" "kew"; }
            Mod+Alt+C hotkey-overlay-title="Copy XWayland clipboard to Wayland" { spawn-sh "DISPLAY=:0 ${pkgs.xclip}/bin/xclip -selection clipboard -out | ${pkgs.wl-clipboard}/bin/wl-copy"; }
            Mod+Alt+V hotkey-overlay-title="Copy Wayland clipboard to XWayland" { spawn-sh "${pkgs.wl-clipboard}/bin/wl-paste | DISPLAY=:0 ${pkgs.xclip}/bin/xclip -selection clipboard"; }
            Mod+Print hotkey-overlay-title="Record selected region" { spawn "nyx-record-region"; }
            Mod+Shift+Print hotkey-overlay-title="Stop screen recording" { spawn "nyx-record-stop"; }
      ''
      ''active-color "${colors.base0D}"''
      ''inactive-color "${colors.base03}"''
      ''active-color "${colors.base0E}"''
      ''urgent-color "${colors.base08}"''
      ''color "${colors.base00}cc"''
      ''
        // Start DankMaterialShell as the Niri shell.
        spawn-at-startup "${lib.getExe pkgs.dms-shell}" "run"
      ''
      ''Mod+D hotkey-overlay-title="Open launcher: DankMaterialShell" { spawn "${lib.getExe pkgs.dms-shell}" "ipc" "call" "spotlight" "toggle"; }''
      "    Print hotkey-overlay-title=\"Screenshot selected area\" { screenshot; }\n"
      "    Ctrl+Print hotkey-overlay-title=\"Screenshot focused screen\" { screenshot-screen; }\n"
      "    Alt+Print hotkey-overlay-title=\"Screenshot focused window\" { screenshot-window; }\n"
    ]
    defaultConfig;
in
lib.mkIf config.nyx.desktop.niri.enable (lib.mkMerge [
{
  hm.home.packages = with pkgs; [
    kdePackages.ark
    kdePackages.breeze
    kdePackages.konsole
    ffmpegthumbnailer
    kew
    mpv
    nyx-recorder
    swayimg
    iconPackage
    thunar
    thunar-archive-plugin
    thunar-volman
    tumbler
    wf-recorder
    wl-clipboard
    xarchiver
    xclip
  ];

  hm.xdg.mimeApps = {
    enable = true;
    defaultApplications =
      {
        "inode/directory" = fileManagerDesktopFile;
      }
      // lib.genAttrs mediaMimeTypes (_: mediaPlayerDesktopFile)
      // lib.genAttrs imageMimeTypes (_: imageViewerDesktopFile);
    associations.added =
      {
        "inode/directory" = [ fileManagerDesktopFile ];
      }
      // lib.genAttrs mediaMimeTypes (_: [ mediaPlayerDesktopFile ])
      // lib.genAttrs imageMimeTypes (_: [ imageViewerDesktopFile ]);
  };

  hm.xdg.desktopEntries.kew = {
    name = "Kew";
    genericName = "Music Player";
    comment = "Terminal music player";
    exec = "alacritty -e kew";
    terminal = false;
    categories = [ "Audio" "AudioVideo" "Player" ];
  };

  hm.xdg.desktopEntries.looking-glass-client = {
    name = "Looking Glass Client";
    genericName = "Virtual Machine Viewer";
    comment = "Client for Looking Glass KVMFR";
    exec = "${pkgs.looking-glass-client}/bin/looking-glass-client";
    icon = "looking-glass";
    terminal = false;
    categories = [ "System" ];
    settings = {
      Keywords = "KVM;VM;VFIO;";
      StartupWMClass = "looking-glass-client";
      SingleMainWindow = "true";
    };
  };

  hm.xdg.configFile."mpv/mpv.conf".text = ''
    save-position-on-quit
    hwdec=auto-safe
  '';

  hm.xdg.configFile."xfce4/helpers.rc".text = ''
    TerminalEmulator=alacritty
    FileManager=Thunar
  '';

  hm.gtk = {
    enable = true;
    iconTheme = lib.mkIf (!stylixIconsEnabled) {
      package = iconPackage;
      name = iconTheme;
    };
  };

  hm.home.pointerCursor = {
    enable = true;
    package = cursorPackage;
    name = cursorTheme;
    size = niriCursorSize;
    gtk.enable = true;
    x11.enable = true;
  };

  hm.home.sessionVariables = {
    XCURSOR_THEME = cursorTheme;
    XCURSOR_SIZE = toString niriCursorSize;
  };

  hm.dconf.settings."org/gnome/desktop/interface" = {
    cursor-theme = cursorTheme;
    cursor-size = niriCursorSize;
    icon-theme = iconTheme;
  };

  hm.xdg.dataFile."color-schemes/RosPine.colors".text = qtColorScheme;

  hm.xdg.configFile."kdeglobals".text = ''
    [General]
    ColorScheme=RosPine
    TerminalApplication=konsole
    TerminalService=org.kde.konsole.desktop
    desktopFont=${sansFont},${toString desktopFontSize},-1,5,50,0,0,0,0,0
    fixed=${monospaceFont},${toString appFontSize},-1,5,50,0,0,0,0,0
    font=${sansFont},${toString appFontSize},-1,5,50,0,0,0,0,0
    menuFont=${sansFont},${toString desktopFontSize},-1,5,50,0,0,0,0,0
    smallestReadableFont=${sansFont},${toString desktopFontSize},-1,5,50,0,0,0,0,0
    taskbarFont=${sansFont},${toString desktopFontSize},-1,5,50,0,0,0,0,0
    toolBarFont=${sansFont},${toString desktopFontSize},-1,5,50,0,0,0,0,0

    [Icons]
    Theme=${iconTheme}

    [KDE]
    LookAndFeelPackage=stylix

    [UiSettings]
    ColorScheme=RosPine

    [WM]
    activeFont=${sansFont},${toString desktopFontSize},-1,5,50,0,0,0,0,0
  '';

  hm.home.activation.wipeDolphinConfig =
    config.hm.lib.dag.entryAfter [ "writeBoundary" ] ''
      for path in \
        "$HOME/.cache/dolphin" \
        "$HOME/.config/dolphinrc" \
        "$HOME/.config/kde-mimeapps.list" \
        "$HOME/.local/share/dolphin" \
        "$HOME/.local/state/dolphinstaterc"
      do
        if [ -e "$path" ] || [ -L "$path" ]; then
          rm -rf "$path"
        fi
      done
    '';

  hm.home.activation.writeDmsSettings =
    config.hm.lib.dag.entryAfter [ "writeBoundary" ] ''
      install -Dm0644 ${dmsSettingsJson} "$HOME/.config/DankMaterialShell/settings.json"
      install -Dm0644 ${dmsSessionJson} "$HOME/.local/state/DankMaterialShell/session.json"
    '';

  hm.xdg.configFile."fuzzel/fuzzel.ini".text = ''
    [main]
    font=${monospaceFont}:size=${toString appFontSize}
    terminal=alacritty -e
    icon-theme=${iconTheme}
    icons-enabled=yes
    prompt="run "
    placeholder=Search applications
    width=48
    lines=12
    horizontal-pad=18
    vertical-pad=14
    inner-pad=8
    layer=overlay

    [colors]
    background=${palette.base00}f2
    text=${palette.base05}ff
    prompt=${palette.base0D}ff
    placeholder=${palette.base04}ff
    input=${palette.base05}ff
    match=${palette.base09}ff
    selection=${palette.base0D}ff
    selection-text=${palette.base00}ff
    selection-match=${palette.base00}ff
    counter=${palette.base04}ff
    border=${palette.base0D}ff

    [border]
    width=2
    radius=10
    selection-radius=6
  '';

  hm.xdg.configFile."mako/config".text = ''
    sort=-time
    layer=overlay
    anchor=top-right
    width=420
    height=160
    margin=8,8,0,0
    padding=10
    border-size=2
    border-radius=8
    icons=1
    max-icon-size=32
    max-visible=5
    default-timeout=5000
    ignore-timeout=0
    background-color=${colors.base00}f2
    text-color=${colors.base05}ff
    border-color=${colors.base0D}ff
    progress-color=over ${colors.base0D}ff

    [urgency=low]
    default-timeout=3000
    border-color=${colors.base03}ff

    [urgency=normal]
    default-timeout=5000

    [urgency=high]
    default-timeout=9000
    border-color=${colors.base08}ff
  '';

  hm.home.activation.reloadMako =
    config.hm.lib.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.mako}/bin/makoctl reload >/dev/null 2>&1 || true
    '';

  hm.qt.qt5ctSettings.Appearance = {
    custom_palette = lib.mkForce false;
    icon_theme = iconTheme;
  };

  hm.qt.qt6ctSettings.Appearance = {
    custom_palette = lib.mkForce false;
    icon_theme = iconTheme;
  };

  hm.programs.alacritty = {
    enable = true;
    settings = {
      window = {
        decorations = "None";
        opacity = lib.mkForce 0.86;
        padding = {
          x = 10;
          y = 10;
        };
      };
    };
  };

  hm.xdg.configFile."niri/config.kdl".text =
    ''
      prefer-no-csd

      window-rule {
          draw-border-with-background false
      }

      window-rule {
          match app-id="^looking-glass-client$"
          open-on-output "DP-1"
          open-maximized-to-edges true
          default-column-width { proportion 1.0; }
          draw-border-with-background false
          variable-refresh-rate true
      }

      output "DP-2" {
          mode "2560x1440@179.960"
          scale 1
          transform "normal"
          position x=0 y=0
          variable-refresh-rate
      }

      output "DP-1" {
          mode "2560x1440@279.960"
          scale 1
          transform "normal"
          position x=2560 y=0
          variable-refresh-rate
          focus-at-startup
      }

      output "DP-3" {
          mode "2560x1440@179.960"
          scale 1
          transform "normal"
          position x=5120 y=0
          variable-refresh-rate
      }

        ''
        + quantaConfig;
}
  (lib.mkIf stylixEnabled {
    hm.stylix.targets.waybar.enable = false;
  })
])
