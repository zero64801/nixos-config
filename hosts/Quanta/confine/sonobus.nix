{ pkgs, ... }:

let
  # Must match "Use Specific UDP Port" in the SonoBus options, the sandbox only receives on this one.
  port = 40404;
in
{
  my.confine.apps.sonobus = {
    package = pkgs.sonobus;
    appId = "net.sonobus.SonoBus";

    profile = [
      "gui"
      "audio"
    ];

    # A C++ parser for peer UDP, kept off host loopback. The LAN and the public connection server still route.
    network = "isolated";
    networkPorts.fromHost = [ port ];

    # JUCE has no Wayland backend, a private Xwayland keeps it away from other X clients.
    x11 = "isolated";

    # JUCE speaks ALSA, the pipewire plugin reads this to land the stream on the virtual mic instead of the headphones.
    env.PIPEWIRE_NODE = "phone_mic_sink";
  };

  networking.firewall.allowedUDPPorts = [ port ];

  # Whatever SonoBus plays into the sink comes out of the source, which Discord and games pick as a microphone.
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
