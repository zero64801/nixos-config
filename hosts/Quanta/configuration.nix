{
  config,
  lib,
  pkgs,
  sources,
  ...
}: let
  inherit (lib) mkForce optional;
in {
  imports = [
    (sources.impermanence + "/nixos.nix")
    (sources.disko + "/module.nix")
    ./disko-config.nix
    ./hardware-configuration.nix
    ./user-configuration.nix
    ../../users/dx.nix
  ];

  system.stateVersion = "25.05"; # Did you read the comment?
  networking.hostName = "Quanta";
  time.timeZone = "America/Sao_Paulo";

  nyx = {
    graphics = {
      enable = true;
      amd.enable = true;
    };

    desktop.kde.enable = true;
    security.yubikey.enable = true;

    programs = {
      zeditor.enable = true;
      helix.enable = true;
      keyd.enable = false;
      flatpak.enable = true;
    };

    impermanence = {
      enable = true;
      mainPersistRoot = "/persist/local";

      roots."/persist/local" = {
        hideMounts = true;

        directories = [
          "/var/log"
          "/var/lib/nixos"
          "/var/lib/flatpak"
          "/var/lib/NetworkManager"
          "/etc/NetworkManager/system-connections"
        ];

        files = [
          "/etc/machine-id"
          "/etc/adjtime"
        ];

        users.dx = {
          directories = [
            "nixos"
            ".var"
            ".local/share/direnv"
            ".local/share/fish"
            "Downloads"
            "Pictures/Wallpapers"
          ];

          files = [
            ".config/monitors.xml"
          ];
        };
      };
    };

    virtualisation = {
      base.enable = true;

      desktop = {
        vfio = {
          enable = true;
          ids = [ "10de:2489" "10de:228b" "1912:0014" ];
        };

        looking-glass = {
          enable = true;
          staticSizeMb = 32;
        };

        hooks.win11 = pkgs.writeShellScript "win11-vfio-hook.sh" ''
          #!${pkgs.bash}/bin/bash
          set -e
          set -x

          HOST_CORES="0-3,8-11"
          ALL_CORES="0-15"

          VM_NAME="$1"
          OPERATION="$2"
          SUB_OPERATION="$3"

          SYSTEMCTL="${pkgs.systemd}/bin/systemctl"

          case "$OPERATION/$SUB_OPERATION" in
          "prepare/begin")
              echo "VFIO-HOOK: Starting for $VM_NAME"
              echo "VFIO-HOOK: Isolating CPUs. Host will use cores: $HOST_CORES"
              $SYSTEMCTL set-property --runtime -- user.slice AllowedCPUs=$HOST_CORES
              $SYSTEMCTL set-property --runtime -- system.slice AllowedCPUs=$HOST_CORES
              $SYSTEMCTL set-property --runtime -- init.scope AllowedCPUs=$HOST_CORES
          ;;

          "release/end")
              echo "VFIO-HOOK: Stopping for $VM_NAME"
              echo "VFIO-HOOK: Restoring all CPU cores ($ALL_CORES) to host"
              $SYSTEMCTL set-property --runtime -- user.slice AllowedCPUs=$ALL_CORES
              $SYSTEMCTL set-property --runtime -- system.slice AllowedCPUs=$ALL_CORES
              $SYSTEMCTL set-property --runtime -- init.scope AllowedCPUs=$ALL_CORES
          ;;
          esac
        '';
      };
    };
  };

  # forward dns onto the tailnet
  networking.firewall.allowedTCPPorts = [ 8080 5001 ];
  networking.firewall.allowedUDPPorts = [ 5353 ];

  # generic
  programs = {
  };

  systemd.user.services.set-default-audio-device = {
    description = "Set default audio sink";
    wantedBy = [ "pipewire-session-manager.service" ];
    after = [ "pipewire-session-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "set-default-audio" ''
        # Wait a moment for devices to be fully registered
        sleep 2

        # Find the sink by name and set it as default
        ${pkgs.wireplumber}/bin/wpctl status | \
          ${pkgs.gnugrep}/bin/grep -A 999 "Audio" | \
          ${pkgs.gnugrep}/bin/grep "Family 17h/19h/1ah HD Audio Controller Analog Stereo" | \
          ${pkgs.gnugrep}/bin/grep -oP '\d+(?=\.)' | \
          head -n1 | \
          xargs -I {} ${pkgs.wireplumber}/bin/wpctl set-default {}
      ''}";
    };
  };

  users.mutableUsers = false;

  # This is for the monitor input switching feature unique to this machine.
  boot.kernelModules = [ "i2c-dev" ];
  users.groups.i2c = {};
  nyx.security.serviceAdminGroups = [ "i2c" ];

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", DRIVER=="pcieport", ATTR{power/wakeup}="disabled"
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  '';

  services.displayManager.autoLogin = {
    enable = true;
    user = "dx";
  };

  # Enable weekly SSD TRIM service (SSD optimization)
  services.fstrim.enable = true;

  # btrfs
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = ["/"];
  };

  # disable network manager wait online service (+6 seconds to boot time!!!!)
  systemd.services.NetworkManager-wait-online.enable = false;

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  users.users.dx.extraGroups = ["tss"];
}
