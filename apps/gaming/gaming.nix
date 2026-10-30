{ config, lib, pkgs, ... }:

let
  cfg = config.my.apps.gaming;
  user = config.my.flake.user;
in
{
  options.my.apps.gaming = {
    enable = lib.mkEnableOption "Gaming support";

    steam = {
      enable = lib.mkEnableOption "Steam";
      remotePlay = lib.mkEnableOption "Steam Remote Play";
      dedicatedServer = lib.mkEnableOption "Steam Dedicated Server";
      localTransfer = lib.mkEnableOption "Steam Local Network Game Transfers";

      compatPackages = lib.mkOption {
        type = with lib.types; listOf package;
        default = [ ];
        description = "Compatibility tools added to Steam's extraCompatPackages (e.g. custom Proton builds).";
      };
    };

    heroic = {
      enable = lib.mkEnableOption "Heroic Launcher";

      protonTools = lib.mkOption {
        type = with lib.types; attrsOf package;
        default = { };
        description = ''
          Proton tools linked into Heroic's tools/proton directory, keyed by
          link name. Each package must expose a `steamcompattool` output.
        '';
      };
    };

    x3dCacheBias = lib.mkEnableOption ''
      Toggle amd_x3d_vcache driver to "cache" mode while a game is running
      via gamemode start/end hooks (and revert to "frequency" on exit).
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = with pkgs;
        [ mangohud ]
        ++ lib.optionals cfg.heroic.enable [ heroic ];

      programs.gamemode = {
        enable = true;
        # The same governor both ways disables gamemode's flip because it hits VM-claimed cores and governor=performance rejects all other EPP writes.
        settings.general = {
          desiredgov = "powersave";
          defaultgov = "powersave";
        };
        settings.custom = let
          scxCfg = config.my.apps.scx;
          switch = "${scxCfg.package}/bin/scx-switch";
          scxEnabled = scxCfg.gameScheduler != "" && scxCfg.gameScheduler != null;

          x3dStart = lib.optionalString cfg.x3dCacheBias ''
            for f in /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode; do
              echo cache > "$f" 2>/dev/null || true
            done
          '';
          x3dEnd = lib.optionalString cfg.x3dCacheBias ''
            for f in /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode; do
              echo frequency > "$f" 2>/dev/null || true
            done
          '';

          startScript = pkgs.writeShellScript "gamemode-start" ''
            ${x3dStart}
            ${lib.optionalString scxEnabled "/run/wrappers/bin/pkexec ${switch} game"}
          '';
          endScript = pkgs.writeShellScript "gamemode-end" ''
            ${x3dEnd}
            ${lib.optionalString scxEnabled "/run/wrappers/bin/pkexec ${switch} host"}
          '';

          anyHookEnabled = scxEnabled || cfg.x3dCacheBias;
        in lib.mkIf anyHookEnabled {
          start = "${startScript}";
          end   = "${endScript}";
        };
      };

      services.udev.extraRules = lib.mkIf cfg.x3dCacheBias ''
        ACTION=="add|bind", DRIVER=="amd_x3d_vcache", RUN+="${pkgs.runtimeShell} -c '${pkgs.coreutils}/bin/chgrp gamemode /sys%p/amd_x3d_mode; ${pkgs.coreutils}/bin/chmod g+w /sys%p/amd_x3d_mode'"
      '';

      # Realtime priority comes from the gamescope-rt helper because capSysNice breaks inside Steam's container.
      programs.gamescope.enable = true;

      programs.steam = lib.mkIf cfg.steam.enable {
        enable = true;
        remotePlay.openFirewall = cfg.steam.remotePlay;
        dedicatedServer.openFirewall = cfg.steam.dedicatedServer;
        localNetworkGameTransfers.openFirewall = cfg.steam.localTransfer;

        extraCompatPackages = cfg.steam.compatPackages;

        extraPackages = [ pkgs.gamescope ];
      };
    }

    (lib.mkIf cfg.heroic.enable {
      systemd.tmpfiles.rules = [
        "d /home/${user}/.config/heroic/tools/proton 0755 ${user} users -"
      ]
      ++ lib.mapAttrsToList
        (name: tool:
          "L+ /home/${user}/.config/heroic/tools/proton/${name} - - - - ${tool.steamcompattool}")
        cfg.heroic.protonTools;
    })

    {
      my.persistence.home.directories =
        [ ".cache/mesa_shader_cache" ]
        ++ lib.optionals cfg.steam.enable [
          ".local/share/Steam"
          ".steam"
          ".local/share/vulkan"
        ]
        ++ lib.optionals cfg.heroic.enable [
          ".config/heroic"
          ".local/share/umu"
        ];
    }
  ]);
}
