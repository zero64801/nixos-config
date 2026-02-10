{ config, pkgs, lib, ... }:

let
  hostname = "Quanta";
  username = "dx";

  defaultAudioScript = pkgs.writeShellScript "set-default-audio" ''
    WPCTL=${lib.getExe' pkgs.wireplumber "wpctl"}
    GREP=${lib.getExe pkgs.gnugrep}

    # Wait for device to appear
    # -q suppresses output, so we just check exit code
    until $WPCTL status | $GREP -q "FIIO KA15 Analog Stereo"; do
      sleep 1
    done

    # Extract ID using Regex
    # This remains brittle because it parses UI text, but it's cleaner here.
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
  imports = [
    ../../users/dx.nix
  ];

  system.stateVersion = "25.11";
  networking.hostName = hostname;

  nyx = {
    flake = {
      host = hostname;
      user = username;
    };

    desktop = {
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

    programs = {
      flatpak.enable = true;
      gaming = {
        enable = true;
        steam.enable = true;
      };
    };
  };

  # Host-specific environment
  environment.systemPackages = with pkgs; [
    lact
  ];
  
  services.lact.enable = true;
  
  # --- Standard Security & Power ---
  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  powerManagement.cpuFreqGovernor = "ondemand";

  # --- Services ---
  services.fstrim.enable = lib.mkDefault true;

  # BTRFS maintenance
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  # Auto-login
  services.displayManager.autoLogin = {
    enable = true;
    user = username;
  };

  # Disable slow services
  systemd.services.NetworkManager-wait-online.enable = lib.mkDefault false;

  # --- Hardware Rules (Udev) ---
  services.udev.extraRules = ''
    # Disable wakeup on PCIe ports to save power/prevent random wakes
    ACTION=="add", SUBSYSTEM=="pci", DRIVER=="pcieport", ATTR{power/wakeup}="disabled"

    # Allow 'i2c' group access to i2c devices
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  '';

  # --- User Services ---
  systemd.user.services.set-default-audio-device = {
    description = "Set default audio sink and volume for FIIO KA15";
    # Ensuring we wait for the sound server to be active
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" "wireplumber.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = defaultAudioScript;
      # Optional: prevents the service from running forever if script hangs
      TimeoutStartSec = "30s";
    };
  };
}
