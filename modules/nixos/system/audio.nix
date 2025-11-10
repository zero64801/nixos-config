{ config, lib, ... }:

{
  config = lib.mkIf (!config.nyx.data.headless) {
    # Disable PulseAudio
    services.pulseaudio.enable = false;

    # Enable realtime kit
    security.rtkit.enable = true;

    # Configure PipeWire
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;

      wireplumber = {
        enable = true;
        extraConfig = {
          "10-disable-camera" = {
            "wireplumber.profiles" = {
              main."monitor.libcamera" = "disabled";
            };
          };
        };
      };
    };
  };
}
