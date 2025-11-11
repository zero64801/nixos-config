{
  lib,
  pkgs,
  osConfig,
  ...
}:
{
  config = lib.mkIf osConfig.nyx.desktop.plasma6.enable {
    programs.plasma = {
      enable = true;

      workspace = {
        clickItemTo = "open";
        lookAndFeel = "org.kde.breezedark.desktop";
        cursor = {
          theme = "Bibata-Modern-Ice";
          size = 24;
        };
        iconTheme = "Tela-dark";
        theme = "breeze-dark";
        wallpaper = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/Elarun/contents/images/2560x1600.png";
      };

      panels = [
        {
          location = "bottom";
          widgets = [
            {
              kickoff = {
                sortAlphabetically = true;
                icon = "kde";
              };
            }
            {
              iconTasks = {
                launchers = [
                  "applications:org.kde.dolphin.desktop"
                  "applications:org.kde.konsole.desktop"
                  "applications:firefox.desktop"
                ];
              };
            }
            "org.kde.plasma.marginsseparator"
            {
              systemTray.items = {
                shown = [
                  "org.kde.plasma.networkmanagement"
                  "org.kde.plasma.volume"
                ];
              };
            }
            {
              digitalClock = {
                calendar.firstDayOfWeek = "monday";
                time.format = "24h";
              };
            }
          ];
        }
      ];

      kwin = {
        edgeBarrier = 0;
        cornerBarrier = false;
      };

      configFile = {
        baloofilerc."Basic Settings"."Indexing-Enabled" = false;
        kdeglobals = {
          General = {
            ColorScheme = "BreezeDark";
          };
          Icons = {
            Theme = "Tela-dark";
          };
        };
        # KScreen configuration for display layout
        kscreenrc = {
          "Display-HDMI-A-1" = {
            Position = "0,0"; # Secondary monitor on the left
          };
          "Display-DP-2" = {
            Position = "1920,0"; # Primary monitor
          };
        };
      };
    };
  };
}
