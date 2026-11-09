{ config, lib, pkgs, ... }:

let
  displayGpu = "0000:05:00.0";

  layoutScript = pkgs.writeShellScript "display-layout" ''
    KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor

    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    WAYLAND_DISPLAY=""
    for _ in $(seq 1 30); do
      for s in "$XDG_RUNTIME_DIR"/wayland-*; do
        [ -S "$s" ] && WAYLAND_DISPLAY=''${s##*/} && break
      done
      [ -n "$WAYLAND_DISPLAY" ] && break
      sleep 0.5
    done
    [ -n "$WAYLAND_DISPLAY" ] || exit 0
    export WAYLAND_DISPLAY
    export QT_QPA_PLATFORM=wayland

    LEFT_SERIAL="HX5L500216"
    CENTER_SERIAL="HX5L400073"
    RIGHT_SERIAL="HX5L500186"
    MODE="2560x1440@180"

    for _ in $(seq 1 30); do
      ( ulimit -c 0; exec "$KSCREEN" -o ) >/dev/null 2>&1 && break
      sleep 0.5
    done

    current=$("$KSCREEN" -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')

    matches() {
      printf '%s\n' "$current" | awk -v conn="$1" -v pos="$2" -v mode="$3" -v vrr="$4" -v prio="$5" '
        $1 == "Output:" { cur = $3; next }
        cur == conn && $1 == "Geometry:" && $2 == pos { g = 1 }
        cur == conn && $1 == "Modes:" {
          for (i = 2; i <= NF; i++) if ($i ~ /\*/) {
            split($i, f, /[:@*]/)
            if (f[2] "@" int(f[3] + 0.5) == mode) m = 1
          }
        }
        cur == conn && $1 == "Vrr:" && (tolower($2) == vrr || $2 == "incapable") { v = 1 }
        cur == conn && $1 == "priority" && (prio == "" || $2 == prio) { p = 1 }
        END { exit !(g && m && v && p) }
      '
    }

    args=""
    all_ok=1
    primary_conn=""
    for dev in /sys/class/drm/card*-*; do
      [ -f "$dev/edid" ] || continue
      [ "$(cat "$dev/status")" = "connected" ] || continue
      case "$(readlink -f "$dev/device/device")" in
        */${displayGpu}) ;;
        *) continue ;;
      esac
      name=''${dev##*/}
      conn=''${name#*-}

      if grep -aq "$LEFT_SERIAL" "$dev/edid"; then
        pos="0,0"; vrr="never"; prio=""
      elif grep -aq "$CENTER_SERIAL" "$dev/edid"; then
        pos="2560,0"; vrr="automatic"; prio="1"; primary_conn=$conn
      elif grep -aq "$RIGHT_SERIAL" "$dev/edid"; then
        pos="5120,0"; vrr="never"; prio=""
      else
        continue
      fi

      matches "$conn" "$pos" "$MODE" "$vrr" "$prio" || all_ok=0
      args="$args output.$conn.enable output.$conn.position.$pos output.$conn.mode.$MODE output.$conn.vrrpolicy.$vrr output.$conn.brightness.100"
    done

    [ -n "$args" ] || exit 0
    [ "$all_ok" = 1 ] && exit 0
    for _ in $(seq 1 10); do
      if "$KSCREEN" $args; then
        [ -z "$primary_conn" ] || "$KSCREEN" "output.$primary_conn.primary"
        exit 0
      fi
      sleep 1
    done
    exit 1
  '';
in
{
  config = lib.mkIf config.my.desktop.plasma6.enable {
    my.desktop.plasma6.extraSpectacleOcrLanguages = [
      "jpn"
      "jpn_vert"
    ];

    hm.xdg.configFile."plasma-workspace/env/kwin-drm-devices.sh".text = ''
      KWIN_DRM_DEVICES=$(readlink -f /dev/dri/by-path/pci-${displayGpu}-card)
      export KWIN_DRM_DEVICES
    '';

    hm.home.packages = with pkgs; [
      haruna
    ];

    hm.programs.plasma = {
      enable = true;

      hotkeys.commands = {
        dev-workspace = {
          name = "Open Visual Studio Code";
          key = "Meta+C";
          command = "code";
        };

        looking-glass = {
          name = "Open Looking Glass";
          key = "Meta+Shift+G";
          command = lib.getExe pkgs.looking-glass-client;
        };
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

    services.udev.extraRules = ''
      ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", RUN+="${pkgs.systemd}/bin/systemctl --no-block -M ${config.my.flake.user}@ --user start display-layout.service"
    '';

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
  };
}
