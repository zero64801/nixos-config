{ config, lib, pkgs, ... }:

let
  # PCI address of the GPU that owns the desktop session; the kwin pin and the monitor layout script both key off it.
  displayGpu = "0000:05:00.0";

  layoutScript = pkgs.writeShellScript "display-layout" ''
    KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor

    # Monitors are identified by EDID serial so the layout survives connector renumbering.
    LEFT_SERIAL="J1FYHV3"
    CENTER_SERIAL="GM0NNP3"
    RIGHT_SERIAL="2S6YHV3"

    # kwin's output management comes up slightly after the session target; poll briefly.
    for _ in $(seq 1 30); do
      "$KSCREEN" -o >/dev/null 2>&1 && break
      sleep 0.5
    done

    args=""
    for dev in /sys/class/drm/card*-*; do
      [ -f "$dev/edid" ] || continue
      [ "$(cat "$dev/status")" = "connected" ] || continue
      # Only the display GPU's connectors: the same monitor may also be cabled to the passthrough card for direct output.
      case "$(readlink -f "$dev/device/device")" in
        */${displayGpu}) ;;
        *) continue ;;
      esac
      name=''${dev##*/}
      conn=''${name#*-}

      if grep -aq "$LEFT_SERIAL" "$dev/edid"; then
        pos="0,0"; extra=""
      elif grep -aq "$CENTER_SERIAL" "$dev/edid"; then
        pos="2560,0"; extra=" output.$conn.primary"
      elif grep -aq "$RIGHT_SERIAL" "$dev/edid"; then
        pos="5120,0"; extra=""
      else
        continue
      fi

      args="$args output.$conn.enable output.$conn.position.$pos output.$conn.vrrpolicy.automatic output.$conn.brightness.100$extra"
    done

    [ -n "$args" ] || exit 0
    for _ in 1 2 3; do
      if "$KSCREEN" $args; then
        exit 0
      fi
      sleep 1
    done
    exit 1
  '';
in
{
  nyx.desktop.plasma6.extraSpectacleOcrLanguages = [
    "jpn"
    "jpn_vert"
  ];

  # Resolved from by-path at login: cardN shuffles between boots, but kwin only matches literal device nodes, not symlinks.
  hm.xdg.configFile."plasma-workspace/env/kwin-drm-devices.sh".text = ''
    KWIN_DRM_DEVICES=$(readlink -f /dev/dri/by-path/pci-${displayGpu}-card)
    export KWIN_DRM_DEVICES
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

  };

  # A user service instead of plasma-manager's startupScript: those only re-run when their
  # content changes, so a regenerated kwin output config was never re-corrected on login.
  hm.systemd.user.services.display-layout = {
    Unit = {
      Description = "Assert monitor layout and primary by EDID serial";
      After = [ "plasma-workspace.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${layoutScript}";
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };
}
