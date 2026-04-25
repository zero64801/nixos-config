{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.scx;
  scripts = import ./_scripts.nix { inherit pkgs lib; };
  inherit (scripts) scx-env scx-switch scx-gui scx-desktop-item;
in
{
  options.nyx.apps.scx = {
    enable = lib.mkEnableOption "sched-ext scheduler manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = scx-switch;
      description = "The scx-switch package to be used by other modules";
    };

    hostScheduler = lib.mkOption {
      type = lib.types.str;
      default = "scx_bpfland";
      description = ''
        Always-on system-wide sched-ext scheduler. Started by services.scx
        on boot and restored after a game session ends.
      '';
    };

    gameScheduler = lib.mkOption {
      type = lib.types.str;
      default = "scx_lavd";
      description = ''
        Scheduler activated by gamemode while a game is running.
        Set to null/empty to skip per-game switching.
      '';
    };

    gameSchedulerFlags = lib.mkOption {
      type = lib.types.str;
      default = "--performance";
      description = "Extra flags passed to gameScheduler at game start.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      scx-env
      scx-switch
      scx-gui
      scx-desktop-item
      pkgs.qt6.qtwayland
      pkgs.adwaita-qt6
      pkgs.nixos-icons
    ];

    services.scx = {
      enable = true;
      scheduler = cfg.hostScheduler;
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.policykit.exec" &&
            action.lookup("command_line") &&
            action.lookup("command_line").indexOf("${scx-switch}/bin/scx-switch") === 0 &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
