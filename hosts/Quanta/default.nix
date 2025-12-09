{ pkgs, ... }:

{
  imports = [
    # Host-specific
    ./hardware.nix
    ./disko.nix
    ./networking.nix
    ./storage.nix
    ./libvirt

    # User
    ../../users/dx

    # Profiles
    ../../profiles/desktop.nix
  ];

  system.stateVersion = "25.11";
  networking.hostName = "Quanta";

  # Graphics
  nyx.graphics = {
    enable = true;
    primary = "amd";
    amd.enable = true;
    nvidia.enable = true;
  };

  # Desktop
  nyx.desktop.plasma6.enable = true;

  # Security
  nyx.security.yubikey.enable = true;

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  # Power Management
  powerManagement.cpuFreqGovernor = "performance";

  # Programs
  nyx.programs.flatpak.enable = true;

  # Impermanence
  environment.persistence."/persist/local" = {
    hideMounts = true;

    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/flatpak"
      "/var/lib/NetworkManager"
      "/var/lib/systemd/coredump"
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
        ".local/state/cosmic"
        ".local/state/cosmic-comp"
        ".config/cosmic"
        "Downloads"
        "Pictures/Wallpapers"
      ];

      files = [
        ".config/cosmic-initial-setup-done"
      ];
    };
  };

  # Virtualization
  nyx.virtualisation = {
    base.enable = true;

    desktop = {
      vfio = {
        enable = true;
        ids = [
          "10de:2489" # NVIDIA Graphics
          "10de:228b" # NVIDIA Audio
          "1912:0014" # USB Controller
        ];
      };

      # GPU switching between NVIDIA driver and VFIO-PCI
      gpuSwitch = {
        enable = true;
        defaultMode = "vfio"; # Start with vfio-pci driver loaded
        pciAddresses = [
          "0a:00.0" # NVIDIA Graphics
          "0a:00.1" # NVIDIA Audio
        ];
        deviceIds = [
          "10de:2489" # NVIDIA Graphics
          "10de:228b" # NVIDIA Audio
        ];
      };

      looking-glass = {
        enable = true;
        staticSizeMb = 64;
      };
    };
  };

  # System-specific configuration
  users.mutableUsers = false;
  boot.kernelModules = [ "i2c-dev" ];
  users.groups.i2c = { };
  nyx.security.serviceAdminGroups = [ "i2c" ];

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", DRIVER=="pcieport", ATTR{power/wakeup}="disabled"
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  '';

  # Auto-login
  services.displayManager.autoLogin = {
    enable = true;
    user = "dx";
  };

  # BTRFS maintenance
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  # Audio device service
  systemd.user.services.set-default-audio-device = {
    description = "Set default audio sink and volume";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "set-default-audio" ''
        until ${pkgs.wireplumber}/bin/wpctl status | \
          ${pkgs.gnugrep}/bin/grep -q "Family 17h/19h/1ah HD Audio Controller Analog Stereo"; do
          sleep 1
        done

        SINK_ID=$(${pkgs.wireplumber}/bin/wpctl status | \
          ${pkgs.gnugrep}/bin/grep -A 2 "Family 17h/19h/1ah HD Audio Controller Analog Stereo" | \
          ${pkgs.gnugrep}/bin/grep -oP '\d+(?=\.)' | \
          head -n1)

        if [ -n "$SINK_ID" ]; then
          ${pkgs.wireplumber}/bin/wpctl set-default "$SINK_ID"
          ${pkgs.wireplumber}/bin/wpctl set-volume "$SINK_ID" 100%
        fi
      '';
    };
  };
}
