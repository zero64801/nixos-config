{ config, pkgs, lib, ... }:

let
  hostname = "Quanta";
  username = "dx";

  defaultAudioScript = pkgs.writeShellScript "set-default-audio" ''
    WPCTL=${lib.getExe' pkgs.wireplumber "wpctl"}
    GREP=${lib.getExe pkgs.gnugrep}

    # Wait for device to appear
    until $WPCTL status | $GREP -q "FIIO KA15 Analog Stereo"; do
      sleep 1
    done

    # Extract ID — brittle, parses UI text
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
  system.stateVersion = "25.11";
  networking.hostName = hostname;

  nyx = {
    flake = {
      host = hostname;
      user = username;
    };

    desktop = {
      enable = true;
      plasma6.enable = true;
    };

    graphics = {
      enable = true;
      backend = "amd";
    };

    impermanence = {
      enable = true;
      persistentStoragePath = "/persist/local";
      configRepoPath = "/home/dx/nixos";
      persistenceConfigFile = ./persist.json;

      btrfs = {
        enable = true;
        device = "/dev/disk/by-label/nixos";
        rootSubvolume = "/root";
        blankSnapshot = "/snapshots/root/blank";
        keepPrevious = true;
        unlockDevice = "dev-mapper-cryptroot.device";
      };
    };

    security = {
      yubikey.enable = true;
      serviceAdminGroups = [ "wheel" ];
    };

    apps = {
      zen.enable = true;
      discord.enable = true;
      fish.enable = true;
      git = {
        enable = true;
        email = "";
      };
      direnv.enable = true;
      zeditor.enable = true;
      flatpak.enable = true;
      scx.enable = true;
      gaming = {
        enable = true;
        steam.enable = true;
      };
    };

    stylix = {
      enable = true;
      scheme = "rose-pine";
      polarity = "dark";
    };
  };

  environment.systemPackages = with pkgs; [
    lact
  ];

  services.lact.enable = true;

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  powerManagement.cpuFreqGovernor = "ondemand";

  services.fstrim.enable = lib.mkDefault true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = username;
  };

  systemd.services.NetworkManager-wait-online.enable = lib.mkDefault false;

  services.udev.extraRules = ''
    # Disable wakeup on PCIe ports
    ACTION=="add", SUBSYSTEM=="pci", DRIVER=="pcieport", ATTR{power/wakeup}="disabled"

    # Allow 'i2c' group access to i2c devices
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  '';

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
