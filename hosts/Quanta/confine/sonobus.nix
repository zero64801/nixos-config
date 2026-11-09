{ pkgs, ... }:

let
  port = 40404;
in
{
  confine.apps.sonobus = {
    package = pkgs.sonobus;
    appId = "net.sonobus.SonoBus";

    profile = [
      "gui"
      "audio"
    ];

    network = "isolated";
    networkPorts.fromHost = [ port ];

    x11 = "isolated";

    env.PIPEWIRE_NODE = "phone_mic_sink";
  };

  networking.firewall.allowedUDPPorts = [ port ];

  services.pipewire.extraConfig.pipewire."90-phone-mic" = {
    "context.modules" = [
      {
        name = "libpipewire-module-loopback";
        args = {
          "node.description" = "iPhone Mic";
          "capture.props" = {
            "node.name" = "phone_mic_sink";
            "media.class" = "Audio/Sink";
            "audio.position" = [ "MONO" ];
          };
          "playback.props" = {
            "node.name" = "phone_mic";
            "media.class" = "Audio/Source";
            "audio.position" = [ "MONO" ];
          };
        };
      }
    ];
  };
}
