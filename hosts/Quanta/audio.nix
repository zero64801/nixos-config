{ pkgs, lib, ... }:

let
  defaultAudioScript = pkgs.writeShellScript "set-default-audio" ''
    WPCTL=${lib.getExe' pkgs.wireplumber "wpctl"}
    GREP=${lib.getExe pkgs.gnugrep}

    until $WPCTL status | $GREP -q "FIIO KA15 Analog Stereo"; do
      sleep 1
    done

    SINK_ID=$($WPCTL status | \
      $GREP -A 2 "FIIO KA15 Analog Stereo" | \
      $GREP -oP '\d+(?=\.)' | \
      head -n1)

    if [ -n "$SINK_ID" ]; then
      $WPCTL set-default "$SINK_ID"
      $WPCTL set-volume "$SINK_ID" 100%
    fi
  '';
in
{
  systemd.user.services.set-default-audio-device = {
    description = "Set default audio sink and volume for FIIO KA15";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" "wireplumber.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = defaultAudioScript;
      TimeoutStartSec = "30s";
    };
  };
}
