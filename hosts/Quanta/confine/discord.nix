{ config, inputs, lib, pkgs, ... }:

let
  nixcordPkgs = inputs.nixcord.packages.${pkgs.stdenv.hostPlatform.system};

  discord = pkgs.callPackage "${inputs.nixcord}/pkgs/discord" {
    openasar = nixcordPkgs.openasar;
  };
in
lib.mkIf config.my.apps.discord.enable {
  confine.apps.discord = {
    package = discord;
    appId = "com.discordapp.Discord";
    install = false;

    profile = [
      "gui"
      "gpu"
      "tray"
      "chromium"
    ];
    pulse = true;

    extraBwrapArgs =
      lib.concatMap (node: [ "--ro-bind" "/dev/null" node ]) [
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
      ]
      ++ [ "--tmpfs" "/dev/nvidia-caps" ];

    network = "isolated";

    env.NIXOS_SPEECH = "True";

    binds.ro = [
      "xdg-run/speech-dispatcher"

      "Pictures"
      "Videos"
    ];

    binds.rw = [
      ".config/discord"
      ".config/Vencord"
    ];
  };

  systemd.user.sockets.speech-dispatcher.wantedBy = [ "sockets.target" ];

  hm.programs.nixcord.discord.package = config.confine.packages.discord;
}
