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
    flakePath = "/home/${username}/nixos";

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
      nvidia.enable = true;
    };

    virtualisation = {
      base = {
        enable = true;
        #networkIsolation.allowedHostTCPPorts = [ 3000 ];
      };

      desktop = {
        enable = true;

        vfio = {
          enable = true;
          ids = [
            "10de:2204"
            "10de:1aef"
          ];
          pciAddresses = [
            "05:00.0"
            "05:00.1"
          ];
        };

        looking-glass = {
          enable = true;
          staticSizeMb = 64;
          extraClientConfig.win = {
            autoResize = false;
            allowResize = true;
            noScreensaver = true;
          };
        };

        hooks = {
          win11     = ./vms/hooks/win11.sh;
          win11-re  = ./vms/hooks/win11-re.sh;
          win11-x3d = ./vms/hooks/win11-x3d.sh;
        };
      };

      gpuSwitch = {
        enable = true;
        defaultMode = "vfio";
      };

      nixvirt = {
        enable = true;
        domains = [
          {
            definition = ./vms/win11.xml;
            active = null;
            restart = null;
          }
          {
            definition = ./vms/win11-re.xml;
            active = null;
            restart = null;
          }
          {
            definition = ./vms/win11-x3d.xml;
            active = null;
            restart = null;
          }
        ];
      };
    };

    impermanence = {
      enable = true;
      persistentStoragePath = "/persist/local";
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

    pinning = {
      enable = true;
    };

    security = {
      yubikey.enable = true;
      serviceAdminGroups = [ "wheel" ];
    };

    apps = {
      zen.enable = true;
      discord.enable = true;
      vlessProxy.enable = true;
      fish.enable = true;
      git = {
        enable = true;
        email = "zero64801@gmail.com";
        signing.enable = true;
        github.enable = true;
      };
      direnv.enable = true;
      zeditor.enable = true;
      flatpak.enable = true;
      scx.enable = true;
      gaming = {
        enable = true;
        steam.enable = true;
        x3dCacheBias = true;   # 9950X3D: bias to V-Cache CCD during gameplay
      };
      llama-cpp = {
        enable = true;
        cuda = true;
        vulkan = true;
      };
    };

    stylix = {
      enable = true;
      scheme = "rose-pine";
      polarity = "dark";
    };
  };

  environment.systemPackages = with pkgs; [
    nvme-cli
    pciutils
    smartmontools
  ];

  services.lact.enable = true;
  services.displayManager.autoLogin = {
    enable = true;
    user = username;
  };

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  powerManagement.cpuFreqGovernor = "powersave";


  services.fstrim.enable = lib.mkDefault true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  systemd.services.NetworkManager-wait-online.enable = lib.mkDefault false;

  services.udev.extraRules = ''
    # Gen5/high-end NVMe drives already handle deep queues well; avoid extra
    # software scheduling overhead on the host and VM storage drives.
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"

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
