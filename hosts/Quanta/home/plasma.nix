{ config, lib, pkgs, ... }:

{
  nyx.desktop.plasma6.extraSpectacleOcrLanguages = [
    "jpn"
    "jpn_vert"
  ];

  hm.programs.plasma = lib.mkIf config.nyx.desktop.plasma6.enable {
    enable = true;

    workspace = {
      clickItemTo = "open";
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
        powerProfile = "balanced";
        autoSuspend.action = "nothing";
        turnOffDisplay.idleTimeout = "never";
        dimDisplay.enable = false;
      };
    };

    panels = [
      {
        location = "top";
        screen = 0;
        widgets = [
          {
            kickoff = {
              sortAlphabetically = true;
            };
          }
          {
            iconTasks = {
              launchers = [
                "applications:org.kde.dolphin.desktop"
                "applications:org.kde.konsole.desktop"
                "applications:zen-beta.desktop"
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

    window-rules = [
      {
        description = "Open Discord on left monitor";
        match = {
          window-class = {
            value = "discord";
            type = "exact";
            match-whole = false;
          };
        };
        apply.screen = {
          value = 1;
          apply = "force";
        };
        apply.position = {
          value = "0,0";
          apply = "initially";
        };
        apply.size = {
          value = "1256,1440";
          apply = "initially";
        };
      }
      {
        description = "Open Zen on right side of left monitor";
        match = {
          window-class = {
            value = "zen-beta";
            type = "exact";
            match-whole = false;
          };
        };
        apply.screen = {
          value = 1;
          apply = "force";
        };
        apply.position = {
          value = "1256,0";
          apply = "initially";
        };
        apply.size = {
          value = "1304,1440";
          apply = "initially";
        };
      }
    ];

    configFile = {
      baloofilerc."Basic Settings"."Indexing-Enabled" = false;
      kdeglobals = {
        #General.ColorScheme = "BreezeDark";
        #Icons.Theme = "Tela-dark";
        KDE.ShowDeleteCommand = true;
      };

      dolphinrc = {
        General.ShowDeleteCommand = true;
        Confirmation.ConfirmDelete = true;
      };

      # Disable KDE Wallet
      kwalletrc.Wallet = {
        Enabled = false;
        "First Use" = false;
        "Prompt on Open" = false;
      };
    };

    startup.startupScript = {
      displayLayout = {
        text = ''
          KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor

          $KSCREEN \
            output.DP-3.enable output.DP-3.position.0,0 \
            output.DP-2.enable output.DP-2.position.2560,0 output.DP-2.primary

          $KSCREEN output.DP-2.vrrpolicy.automatic
          $KSCREEN output.DP-3.vrrpolicy.automatic

          for out in DP-2 DP-3; do
            $KSCREEN output.$out.brightness.100
          done
        '';
        priority = 1;
      };
    };
  };
}
