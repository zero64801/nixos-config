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
        # No screen-index force: KWin numbers screens primary-first then by
        # cable order, so the index isn't stable. The global position below
        # lands on the left monitor (layout pins it to 0,0) regardless.
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
        # No screen-index force: KWin numbers screens primary-first then by
        # cable order, so the index isn't stable. The global position below
        # lands on the left monitor (layout pins it to 0,0) regardless.
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
          # Lock the layout by each monitor's EDID id (stable per physical
          # panel) instead of by connector name (DP-1/2/3 — those are assigned
          # by cable order and shuffle whenever cables are reinserted). Now any
          # monitor can go in any DP port and still lands in its assigned spot.
          KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor

          PRIMARY_ID=ff9d48bc-a563-47b9-87d9-718be4a50687   # 280Hz panel
          fallback_x=7680   # unknown/new monitors get appended to the right

          pos_for() {
            case "$1" in
              c4680d7a-fca1-4b7c-a753-ec22c83d96e3) echo "0,0" ;;      # 180Hz  -> left
              ff9d48bc-a563-47b9-87d9-718be4a50687) echo "2560,0" ;;   # 280Hz  -> center (primary)
              9b135a80-e57e-49a9-a7f9-1a8f188959ac) echo "5120,0" ;;   # 180Hz  -> right
              *) echo "" ;;
            esac
          }

          # Map current connectors -> EDID ids and build ONE atomic command:
          # KWin re-normalizes the layout between separate invocations, so
          # per-output calls collide everything at 0,0. Apply it all at once.
          args=$("$KSCREEN" -o | sed 's/\x1b\[[0-9;]*m//g' \
            | awk '/^Output:/ { print $3" "$4 }' \
            | while read -r conn id; do
                [ -n "$conn" ] || continue
                pos=$(pos_for "$id")
                if [ -z "$pos" ]; then
                  pos="''${fallback_x},0"
                  fallback_x=$((fallback_x + 2560))
                fi
                printf ' output.%s.enable output.%s.position.%s output.%s.vrrpolicy.automatic output.%s.brightness.100' \
                  "$conn" "$conn" "$pos" "$conn" "$conn"
                [ "$id" = "$PRIMARY_ID" ] && printf ' output.%s.primary' "$conn"
              done)

          # word-splitting on $args is intentional (each op is a separate arg)
          [ -n "$args" ] && "$KSCREEN" $args
        '';
        priority = 1;
      };
    };
  };
}
