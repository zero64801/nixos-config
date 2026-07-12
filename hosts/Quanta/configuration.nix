{ pkgs, lib, ... }:

let
  hostname = "Quanta";
  username = "dx";

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
  system.stateVersion = "25.11";
  networking.hostName = hostname;

  nyx = {
    flakePath = "/home/${username}/nixos";

    flake.user = username;

    cli.enable = true;

    desktop = {
      enable = true;
      plasma6.enable = true;
    };

    graphics = {
      enable = true;
      backend = "amd";
      nvidia = {
        enable = true;
        drm.enable = true;
      };
    };

    virtualisation = {
      base = {
        enable = true;
      };

      desktop = {
        enable = true;

        vfio = {
          enable = true;
          ids = [
            "10de:2b85"
            "10de:22e8"
          ];
          pciAddresses = [
            "01:00.0"
            "01:00.1"
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

      };

      cpuPinning = {
        enable = true;
        domains = [ "win11" "win11-re" ];
        defaultMode = "classic";
        modes = {
          # CCD1 (8-15 + SMT 24-31): higher clocks, host keeps the X3D CCD.
          classic = {
            vcpuPins = [ 8 24 9 25 10 26 11 27 12 28 13 29 14 30 15 31 ];
            emulatorCpus = "0-1,16-17";
            iothreadCpus = "2,18";
          };
          # CCD0 (0-7 + SMT 16-23): the V-Cache CCD goes to the guest.
          x3d = {
            vcpuPins = [ 0 16 1 17 2 18 3 19 4 20 5 21 6 22 7 23 ];
            emulatorCpus = "8-9,24-25";
            iothreadCpus = "10,26";
          };
        };
      };

      gpuSwitch = {
        enable = true;
        defaultMode = "host";
      };

      sambaShare = {
        enable = true;
        dropPath = "/mnt/storage/VMs/share/drop";
        exchangePath = "/mnt/storage/VMs/share/exchange";
      };
      nixvirt = {
        enable = true;
        domains = [
          {
            definition = ./vms/win11.xml;
            active = null;
            restart = false;
          }
          {
            definition = ./vms/win11-re.xml;
            active = null;
            restart = false;
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
        name = "zero64801";
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
        x3dCacheBias = true;
      };
      llamaCpp = {
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


  services.fstrim.enable = true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" "/mnt/storage" "/mnt/vault" ];
  };

  fileSystems."/var/lib/samba" = {
    device = "/mnt/storage/samba";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/mnt/storage" ];
  };

  systemd.services.samba-statedir-init = {
    description = "Create the /mnt/storage bind source for /var/lib/samba";
    after = [ "mnt-storage.mount" ];
    before = [ "var-lib-samba.mount" ];
    requiredBy = [ "var-lib-samba.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/mkdir -p /mnt/storage/samba";
    };
  };

  systemd.services.NetworkManager-wait-online.enable = false;

  services.udev.extraRules = ''
    # High-end NVMe controllers handle deep queues internally; skip the software scheduler.
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
