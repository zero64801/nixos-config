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
    ./hardware-configuration.nix
    ./user-configuration.nix
    ../../users/haxxor.nix
  ];

  system.stateVersion = "25.05";
  networking.hostName = "Silverwing";
  networking.hostId = "8425e349";
  time.timeZone = "America/Sao_Paulo";

  nyx = {
    graphics = {
      enable = true;
      intel.enable = true;
      nvidia.enable = true;
    };

    desktop.niri.enable = true;        

    programs = {
      helix.enable = true;
    };

    impermanence = {
      enable = true;
      persistence."/persist/local" = {
        hideMounts = true;

        directories = [
          "/var/log"
          "/var/lib/nixos"
          "/var/lib/NetworkManager"
          "/etc/NetworkManager/system-connections"
          "/var/lib/forgejo"
          "/home/multimedia"
          "/var/lib/jellyfin"
          "/var/lib/sonarr"
          "/var/lib/radarr"
          "/var/lib/transmission"
        ];

        files = [
          "/etc/u2f_keys"
          "/etc/machine-id"
          "/etc/adjtime"
        ];

        users.haxxor = {
          directories = [
            "nixos"
            ".local/share/direnv"
            ".local/share/fish"
            "Downloads"
            "Videos/Jellyfin"
            "Pictures/Wallpapers"
          ];

          files = [
          ];
        };
      };
    };

    services = {
      enable = true;
      tailscale = {
        enable = false;
        exitNode.enable = false;
        authFile = config.age.secrets.tailAuth.path;
      };
      openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = true;
          PermitRootLogin = "yes";
        };
      };
      caddy.enable = true;
      jellyfin.enable = true;
      forgejo.enable = true;
    };
  };

  # forward dns onto the tailnet
  networking.firewall.allowedTCPPorts = [ 8080 80 443 ];
  networking.firewall.allowedUDPPorts = [ 5353 ];

  # generic
  programs = {
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = "haxxor";
  };

  # Enable weekly SSD TRIM service (SSD optimization)
  services.fstrim.enable = true;

  # disabled autosuspend
  services.logind.lidSwitchExternalPower = "ignore";
  
  # disable network manager wait online service (+6 seconds to boot time!!!!)
  systemd.services.NetworkManager-wait-online.enable = false;

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  users.users.haxxor.extraGroups = ["tss"];

  # samsumg silent mode hack
  boot.kernelModules = [ "ec_sys" ];
  boot.extraModprobeConfig = "options ec_sys write_support=1";

  environment.systemPackages = with pkgs; [
    # Creates the 'set-samsung-silent-mode' command
    (writeShellScriptBin "set-samsung-silent-mode" ''
      #!/usr/bin/env bash
      # This script must be run as root to access the Embedded Controller.
      if [ "$(id -u)" -ne 0 ]; then
          echo "Error: This script must be run with sudo." >&2
          exit 1
      fi

      printf '\x01' | dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=142 count=1
      echo "Samsung fan mode set to: Silent"
    '')

    (writeShellScriptBin "set-samsung-normal-mode" ''
      #!/usr/bin/env bash
      # This script must be run as root to access the Embedded Controller.
      if [ "$(id -u)" -ne 0 ]; then
          echo "Error: This script must be run with sudo." >&2
          exit 1
      fi

      printf '\x00' | dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=142 count=1
      echo "Samsung fan mode set to: Normal"
    '')
  ];  
}
