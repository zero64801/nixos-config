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

      # Disable automatic screen locking
      kscreenlocker = {
        autoLock = false;
        lockOnResume = false;
        lockOnStartup = false;
      };

      # Disable auto-suspend and screen turning off
      powerdevil = {
        AC = {
          powerProfile = "performance";
          autoSuspend = {
            action = "nothing";
          };
          turnOffDisplay = {
            idleTimeout = "never";
          };
          dimDisplay = {
            enable = false;
          };
        };
      };

      panels = [
        {
          location = "bottom";
          screen = 0;
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
        # Disable KDE Wallet
        kwalletrc = {
          "Wallet" = {
            "Enabled" = false;
            "First Use" = false;
            "Prompt on Open" = false;
          };
        };
      };

      startup.startupScript = {
        displayLayout = {
          text = ''
            ${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor output.HDMI-A-1.position.0,0 output.DP-3.position.1920,0 output.DP-3.primary

            # Set brightness to 100% for all displays
            for output in HDMI-A-1 DP-3; do
              ${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor output.$output.brightness.100
            done
          '';
          priority = 1;
        };
      };
    };
  };
}
