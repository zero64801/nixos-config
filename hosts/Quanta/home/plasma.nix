{ config, lib, pkgs, ... }:

{
  nyx.desktop.plasma6.extraSpectacleOcrLanguages = [
    "jpn"
    "jpn_vert"
  ];

  hm.xdg.configFile."plasma-workspace/env/kwin-drm-devices.sh".text = ''
    export KWIN_DRM_DEVICES=/dev/dri/card1
  '';

  hm.programs.plasma = lib.mkIf config.nyx.desktop.plasma6.enable {
    enable = true;

    workspace = {
      clickItemTo = "open";
      wallpaper = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/Elarun/contents/images/2560x1600.png";
    };

    kscreenlocker = {
      autoLock = false;
      lockOnResume = false;
      lockOnStartup = false;
    };

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
        KDE.ShowDeleteCommand = true;
      };

      dolphinrc = {
        General.ShowDeleteCommand = true;
        Confirmation.ConfirmDelete = true;
      };

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

          data=$("$KSCREEN" -o | sed 's/\x1b\[[0-9;]*m//g' | awk '
            /^Output:/ { if (conn!="") printf "%s %.0f\n", conn, maxr; conn=$3; maxr=0 }
            /Modes:/ { for (i=1;i<=NF;i++){ p=index($i,"@"); if(p>0){ r=substr($i,p+1); gsub(/[^0-9.].*/,"",r); r=r+0; if(r>maxr)maxr=r } } }
            END { if (conn!="") printf "%s %.0f\n", conn, maxr }
          ')

          center_conn=$(printf '%s\n' "$data" | grep -E '^(DP|HDMI)-' | sort -k2,2 -n | tail -1 | awk '{print $1}')

          args=$(printf '%s\n' "$data" | { side_x=0; while read -r conn maxr; do
            [ -n "$conn" ] || continue
            case "$conn" in
              DP-*|HDMI-*) ;;
              *)
                printf ' output.%s.disable' "$conn"
                continue ;;
            esac
            if [ "$conn" = "$center_conn" ]; then
              pos="2560,0"; extra=" output.$conn.primary"
            else
              pos="''${side_x},0"; extra=""
              [ "$side_x" -eq 0 ] && side_x=5120
            fi
            printf ' output.%s.enable output.%s.position.%s output.%s.vrrpolicy.automatic output.%s.brightness.100%s' \
              "$conn" "$conn" "$pos" "$conn" "$conn" "$extra"
          done; })

          [ -n "$args" ] && "$KSCREEN" $args
        '';
        priority = 1;
      };
    };
  };
}
