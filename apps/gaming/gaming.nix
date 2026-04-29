{ config, lib, pkgs, options, ... }:

let
  cfg = config.nyx.apps.gaming;
  user = config.nyx.flake.user;
  scxPackage = config.nyx.apps.scx.package;
  dwproton = pkgs.dwproton-bin;
in
{
  options.nyx.apps.gaming = {
    enable = lib.mkEnableOption "Gaming support";

    steam = {
      enable = lib.mkEnableOption "Steam";
      remotePlay = lib.mkEnableOption "Steam Remote Play";
      dedicatedServer = lib.mkEnableOption "Steam Dedicated Server";
      localTransfer = lib.mkEnableOption "Steam Local Network Game Transfers";
    };

    heroic.enable = lib.mkEnableOption "Heroic Launcher";

    x3dCacheBias = lib.mkEnableOption ''
      Toggle amd_x3d_vcache driver to "cache" mode while a game is running
      via gamemode start/end hooks (and revert to "frequency" on exit).

      Only meaningful on dual-CCD X3D parts (7900X3D, 7950X3D, 9900X3D,
      9950X3D). Single-CCD X3D parts and non-X3D CPUs don't expose the
      driver and this option is a no-op there.
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = with pkgs;
        [ mangohud ]
        ++ lib.optionals cfg.heroic.enable [ heroic ];

      programs.gamemode = {
        enable = true;
        settings.custom = let
          scxCfg = config.nyx.apps.scx;
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
            ${lib.optionalString scxEnabled
              "${switch} apply ${scxCfg.gameScheduler} ${scxCfg.gameSchedulerFlags}"}
          '';
          endScript = pkgs.writeShellScript "gamemode-end" ''
            ${x3dEnd}
            ${lib.optionalString scxEnabled "${switch} host"}
          '';

          anyHookEnabled = scxEnabled || cfg.x3dCacheBias;
        in lib.mkIf anyHookEnabled {
          start = "/run/wrappers/bin/pkexec ${startScript}";
          end   = "/run/wrappers/bin/pkexec ${endScript}";
        };
      };

      programs.steam = lib.mkIf cfg.steam.enable {
        enable = true;
        remotePlay.openFirewall = cfg.steam.remotePlay;
        dedicatedServer.openFirewall = cfg.steam.dedicatedServer;
        localNetworkGameTransfers.openFirewall = cfg.steam.localTransfer;

        extraCompatPackages = with pkgs; [
          dwproton
          proton-cachyos-v3-bin
        ];
      };
    }

    (lib.mkIf cfg.heroic.enable {
      systemd.tmpfiles.rules = [
        "d /home/${user}/.config/heroic/tools/proton 0755 ${user} users -"
        "L+ /home/${user}/.config/heroic/tools/proton/dwproton - - - - ${dwproton.steamcompattool}"
      ];
    })

    {
      nyx.persistence.home.directories =
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
