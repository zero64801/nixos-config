{ config, lib, pkgs, ... }:

let
  # PCI address of the GPU that owns the desktop session; the kwin pin and the monitor layout script both key off it.
  displayGpu = "0000:05:00.0";

  layoutScript = pkgs.writeShellScript "display-layout" ''
    KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor

    # At login this races Plasma's env import into systemd --user; without WAYLAND_DISPLAY
    # Qt falls back to xcb and aborts, so resolve the session socket directly.
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      for s in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$s" ] || continue
        WAYLAND_DISPLAY=''${s##*/}
        export WAYLAND_DISPLAY
        break
      done
    fi
    export QT_QPA_PLATFORM=wayland

    # Monitors are identified by EDID serial so the layout survives connector renumbering.
    LEFT_SERIAL="J1FYHV3"
    CENTER_SERIAL="GM0NNP3"
    RIGHT_SERIAL="2S6YHV3"

    # kwin's output management comes up slightly after the session target; poll briefly.
    for _ in $(seq 1 30); do
      "$KSCREEN" -o >/dev/null 2>&1 && break
      sleep 0.5
    done

    current=$("$KSCREEN" -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

    # True when the connector already has the wanted position, vrr policy and (optionally) priority.
    matches() {
      printf '%s\n' "$current" | awk -v conn="$1" -v pos="$2" -v vrr="$3" -v prio="$4" '
        $1 == "Output:" { cur = $3; next }
        cur == conn && $1 == "Geometry:" && $2 == pos { g = 1 }
        cur == conn && $1 == "Vrr:" && tolower($2) == vrr { v = 1 }
        cur == conn && $1 == "priority" && (prio == "" || $2 == prio) { p = 1 }
        END { exit !(g && v && p) }
      '
    }

    args=""
    all_ok=1
    primary_conn=""
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

      # VRR automatic only on the gaming display: Plasma 6.7's automatic engages for desktop windows and flickers the side panels.
      if grep -aq "$LEFT_SERIAL" "$dev/edid"; then
        pos="0,0"; vrr="never"; prio=""
      elif grep -aq "$CENTER_SERIAL" "$dev/edid"; then
        pos="2560,0"; vrr="automatic"; prio="1"; primary_conn=$conn
      elif grep -aq "$RIGHT_SERIAL" "$dev/edid"; then
        pos="5120,0"; vrr="never"; prio=""
      else
        continue
      fi

      matches "$conn" "$pos" "$vrr" "$prio" || all_ok=0
      args="$args output.$conn.enable output.$conn.position.$pos output.$conn.vrrpolicy.$vrr output.$conn.brightness.100"
    done

    [ -n "$args" ] || exit 0
    # Reapplying an identical config still emits wl_output events to every client, which retriggers reflow-loop bugs in some apps (Zen). Only touch kwin on drift.
    [ "$all_ok" = 1 ] && exit 0
    for _ in $(seq 1 10); do
      if "$KSCREEN" $args; then
        # Combined with enable/position args kwin renumbers priorities by connector order
        # and drops the primary request, so it must go in its own transaction.
        [ -z "$primary_conn" ] || "$KSCREEN" "output.$primary_conn.primary"
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

  # Sandboxed VSCode from ~/Projects/dev/shell.nix; direnv exec replays the
  # cached nix-direnv env so no terminal or manual nix-shell is needed.
  hm.xdg.desktopEntries.dev-workspace = {
    name = "Dev Workspace";
    genericName = "Code Editor";
    comment = "VSCode in the sandboxed dev environment";
    exec = ''bash -c "cd /home/dx/Projects/dev && exec direnv exec . code"'';
    icon = "code";
    terminal = false;
    categories = [ "Development" "IDE" ];
    settings.StartupWMClass = "Code";
  };

  hm.programs.plasma = lib.mkIf config.nyx.desktop.plasma6.enable {
    enable = true;

    hotkeys.commands.dev-workspace = {
      name = "Open Dev Workspace";
      key = "Meta+C";
      command = ''bash -c "cd /home/dx/Projects/dev && exec direnv exec . code"'';
    };

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

  # Output recreation (monitor sleep, input switch, replug) makes kwin re-derive priority
  # from connector order, stealing primary from the center monitor; re-assert on DRM changes.
  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="${pkgs.systemd}/bin/systemctl --no-block -M ${config.nyx.flake.user}@ --user start display-layout.service"
  '';

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
