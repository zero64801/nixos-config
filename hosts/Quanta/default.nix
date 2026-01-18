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
    amd.enable = true;
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
  powerManagement.cpuFreqGovernor = "ondemand";

  # Programs
  nyx.programs = {
    flatpak.enable = true;
  };

  # Impermanence - paths defined in persistence.nix
  nyx.impermanence = {
    enable = true;
    persistentStoragePath = "/persist/local";
    persistenceConfigFile = ./persistence.nix;
    configRepoPath = "/home/dx/nixos";
    hideMounts = true;

    btrfs = {
      enable = true;
      device = "/dev/disk/by-label/nixos";
      rootSubvolume = "/root";
      blankSnapshot = "/snapshots/root/blank";
      keepPrevious = true;
      unlockDevice = "dev-mapper-cryptroot.device";
    };
  };

  # Virtualization
  nyx.virtualisation.base.enable = true;

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
          ${pkgs.gnugrep}/bin/grep -q "FIIO KA15 Analog Stereo"; do
          sleep 1
        done

        SINK_ID=$(${pkgs.wireplumber}/bin/wpctl status | \
          ${pkgs.gnugrep}/bin/grep -A 2 "FIIO KA15 Analog Stereo" | \
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
