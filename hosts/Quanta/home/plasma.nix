{ config, lib, pkgs, ... }:

{
  nyx.desktop.plasma6.extraSpectacleOcrLanguages = [
    "jpn"
    "jpn_vert"
  ];

  # Pin KWin to the amdgpu device so it never enumerates the 5090's transient
  # simpledrm "phantom" (the leftover firmware framebuffer). Without this, the
  # first time a VFIO VM starts and the 5090 is rebound to vfio, that phantom
  # DRM device disappears, KWin recomputes the layout, and primary reverts from
  # the center monitor to the left one (the layout script only runs at login,
  # not on hotplug). KWIN_DRM_DEVICES is honoured on Plasma < 6.7.
  #
  # card0 = simpledrm (registered early from the EFI fb), card1 = amdgpu (initrd)
  # — stable as long as the firmware framebuffer still appears (fbcon=map:1
  # setup). If that ever changes (e.g. initcall_blacklist=sysfb_init), amdgpu
  # becomes card0 and this must be updated, or KWin will find no device.
  hm.xdg.configFile."plasma-workspace/env/kwin-drm-devices.sh".text = ''
    export KWIN_DRM_DEVICES=/dev/dri/card1
  '';

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
          # Lay out the three monitors by CONNECTOR TYPE, not kscreen UUIDs
          # (those regenerate every boot since impermanence wipes the kscreen
          # state). The main display is routed through the single HDMI port ->
          # center + primary; the two identical side panels are on DP-* and
          # interchangeable -> left/right. (Refresh rate can no longer identify
          # the main panel: over HDMI it's bandwidth-capped to 144Hz, BELOW the
          # 180Hz side panels.) Built as ONE atomic kscreen-doctor call so KWin
          # doesn't re-normalize and collide outputs at 0,0 between invocations.
          KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor

          # connector + its max refresh (Hz) for each connected output
          data=$("$KSCREEN" -o | sed 's/\x1b\[[0-9;]*m//g' | awk '
            /^Output:/ { if (conn!="") printf "%s %.0f\n", conn, maxr; conn=$3; maxr=0 }
            /Modes:/ { for (i=1;i<=NF;i++){ p=index($i,"@"); if(p>0){ r=substr($i,p+1); gsub(/[^0-9.].*/,"",r); r=r+0; if(r>maxr)maxr=r } } }
            END { if (conn!="") printf "%s %.0f\n", conn, maxr }
          ')

          # Center/primary = the monitor on the unique HDMI port. Fall back to
          # the highest-refresh DP if no HDMI output is present. (The phantom
          # simpledrm "Unknown-1" output is neither DP nor HDMI, so it is never
          # chosen here and gets disabled in the loop below.)
          center_conn=$(printf '%s\n' "$data" | grep -E '^HDMI-' | head -1 | awk '{print $1}')
          [ -z "$center_conn" ] && center_conn=$(printf '%s\n' "$data" | grep -E '^DP-' | sort -k2,2 -n | tail -1 | awk '{print $1}')

          args=$(printf '%s\n' "$data" | { side_x=0; while read -r conn maxr; do
            [ -n "$conn" ] || continue
            case "$conn" in
              DP-*|HDMI-*) ;;
              *)
                # Phantom output (e.g. the 5090's leftover simpledrm "Unknown-1"
                # firmware framebuffer, present because nvidia_drm is blacklisted
                # so the GOP fb is never evicted). Disable it so KWin stops
                # enumerating it as a screen and rearranging the layout.
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

          # word-splitting on $args is intentional (each op is a separate arg)
          [ -n "$args" ] && "$KSCREEN" $args
        '';
        priority = 1;
      };
    };
  };
}
