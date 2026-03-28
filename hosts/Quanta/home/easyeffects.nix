{ pkgs, ... }:
{
  hm = {
    services.easyeffects = {
      enable = true;
      preset = "k688";
      extraPresets = {
        k688 = {
          input = {
            blocklist = [ ];

            "plugins_order" = [
              "rnnoise#0"
              "gate#0"
              "equalizer#0"
              "compressor#0"
            ];

            "rnnoise#0" = {
              bypass = false;
              "enable-vad" = false;
              "input-gain" = 4.0;
              "model-path" = "";
              "output-gain" = 0.0;
              release = 20.0;
              "vad-thres" = 50.0;
              wet = 0.0;
            };

            "gate#0" = {
              attack = 5.0;
              bypass = false;
              "curve-threshold" = -18.0;
              "curve-zone" = -6.0;
              "hpf-frequency" = 10.0;
              "hpf-mode" = "off";
              hysteresis = false;
              "hysteresis-threshold" = -12.0;
              "hysteresis-zone" = -6.0;
              "input-gain" = 0.0;
              "lpf-frequency" = 20000.0;
              "lpf-mode" = "off";
              makeup = 0.0;
              "output-gain" = 0.0;
              reduction = -24.0;
              release = 120.0;
            };

            "equalizer#0" = {
              balance = 0.0;
              bypass = false;
              "input-gain" = 0.0;
              mode = "IIR";
              "num-bands" = 5;
              "output-gain" = 0.0;  # was -2.0 — stop throwing away gain

              left = {
                band0 = {
                  frequency = 100.0;  # was 80.0 — K688 has more rumble
                  gain = 0.0;
                  mode = "RLC (BT)";
                  mute = false;
                  q = 0.707;
                  slope = "x2";
                  solo = false;
                  type = "Hi-pass";
                  width = 4.0;
                };
                band1 = {
                  frequency = 220.0;
                  gain = -5.0;  # was -2.0 — deeper mud cut
                  mode = "RLC (BT)";
                  mute = false;
                  q = 1.0;
                  slope = "x1";
                  solo = false;
                  type = "Bell";
                  width = 4.0;
                };
                band2 = {
                  frequency = 400.0;
                  gain = -3.0;  # was -2.0 — supporting the scoop
                  mode = "RLC (BT)";
                  mute = false;
                  q = 1.0;
                  slope = "x1";
                  solo = false;
                  type = "Bell";
                  width = 4.0;
                };
                band3 = {
                  frequency = 4500.0;  # was 3500.0 — SM7B presence peak is higher
                  gain = 3.0;          # was 2.0
                  mode = "RLC (BT)";
                  mute = false;
                  q = 1.2;
                  slope = "x1";
                  solo = false;
                  type = "Bell";
                  width = 4.0;
                };
                band4 = {
                  frequency = 10000.0;
                  gain = 3.0;  # was 2.0 — more air to offset scooping
                  mode = "RLC (BT)";
                  mute = false;
                  q = 0.707;
                  slope = "x1";
                  solo = false;
                  type = "Hi-shelf";
                  width = 4.0;
                };
              };

              right = {
                band0 = {
                  frequency = 100.0;  # was 80.0
                  gain = 0.0;
                  mode = "RLC (BT)";
                  mute = false;
                  q = 0.707;
                  slope = "x2";
                  solo = false;
                  type = "Hi-pass";
                  width = 4.0;
                };
                band1 = {
                  frequency = 220.0;
                  gain = -5.0;  # was -2.0
                  mode = "RLC (BT)";
                  mute = false;
                  q = 1.0;
                  slope = "x1";
                  solo = false;
                  type = "Bell";
                  width = 4.0;
                };
                band2 = {
                  frequency = 400.0;
                  gain = -3.0;  # was -2.0
                  mode = "RLC (BT)";
                  mute = false;
                  q = 1.0;
                  slope = "x1";
                  solo = false;
                  type = "Bell";
                  width = 4.0;
                };
                band3 = {
                  frequency = 4500.0;  # was 3500.0
                  gain = 3.0;          # was 2.0
                  mode = "RLC (BT)";
                  mute = false;
                  q = 1.2;
                  slope = "x1";
                  solo = false;
                  type = "Bell";
                  width = 4.0;
                };
                band4 = {
                  frequency = 10000.0;
                  gain = 3.0;  # was 2.0
                  mode = "RLC (BT)";
                  mute = false;
                  q = 0.707;
                  slope = "x1";
                  solo = false;
                  type = "Hi-shelf";
                  width = 4.0;
                };
              };
            };

            "compressor#0" = {
              attack = 15.0;
              "boost-amount" = 0.0;
              "boost-threshold" = -72.0;
              bypass = false;
              dry = -80.01;
              "hpf-frequency" = 10.0;
              "hpf-mode" = "Off";
              "input-gain" = 0.0;
              "input-to-link" = 0.0;
              "input-to-sidechain" = 0.0;
              knee = -6.0;
              "link-to-input" = 0.0;
              "link-to-sidechain" = 0.0;
              "lpf-frequency" = 20000.0;
              "lpf-mode" = "Off";
              makeup = 9.0;   # was 3.0 — proper gain restoration after deep EQ cuts
              mode = "Downward";
              "output-gain" = 0.0;
              ratio = 3.0;
              release = 200.0;
              "release-threshold" = -40.0;
              sidechain = {
                lookahead = 0.0;
                mode = "RMS";
                preamp = 0.0;
                reactivity = 10.0;
                source = "Middle";
                "stereo-split-source" = "Left/Right";
                type = "Feed-forward";
              };
              "sidechain-to-input" = 0.0;
              "sidechain-to-link" = 0.0;
              "stereo-split" = false;
              threshold = -18.0;
            };
          };
        };
      };
    };
  };
}
