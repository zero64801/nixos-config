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
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = with pkgs;
        [ mangohud ]
        ++ lib.optionals cfg.heroic.enable [ heroic ];

      programs.gamemode = {
        enable = true;
        settings.custom = {
          start = "/run/wrappers/bin/pkexec ${scxPackage}/bin/scx-switch apply scx_lavd --performance";
          end = "/run/wrappers/bin/pkexec ${scxPackage}/bin/scx-switch disable";
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
