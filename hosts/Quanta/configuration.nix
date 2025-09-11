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
    ../../users/dx.nix
  ];

  system.stateVersion = "25.05"; # Did you read the comment?
  networking.hostName = "Quanta";
  time.timeZone = "America/Sao_Paulo";

  nix.settings = {
    extra-substituters = [ "https://chaotic-nyx.cachix.org" ];
    extra-trusted-public-keys = [ "chaotic-nyx.cachix.org-1:HfnXSw4pj95iI/n17rIDy40agHj12WfF+Gqk6SonIT8=" ];
  };

  nyx = {
    graphics = {
      enable = true;
      amd.enable = true;
    };

    desktop.gnome.enable = true;
    virtualisation.enable = true;
    security.yubikey.enable = true;

    programs = {
      helix.enable = true;
      obs-studio.enable = false;
      keyd.enable = false;
      firefox.enable = true;
      flatpak.enable = true;
      privoxy = {
        enable = false;
        forwards = [
          # I shouldn't be exposing myself like this
          {domains = ["www.privoxy.org" ".donmai.us" "rule34.xxx" ".yande.re" "www.zerochan.net" ".kemono.su" "hanime.tv"];}
        ];
      };
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
          "/var/lib/libvirt"
          "/etc/NetworkManager/system-connections"
        ];

        files = [
          "/etc/u2f_keys"
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

    services = {
      enable = true;
      tailscale = {
        enable = false;
        exitNode.enable = false;
        authFile = config.age.secrets.tailAuth.path;
      };
      openssh.enable = false;
    };

    /*
    utils.btrfs-snapshots.dx = [
      {
        subvolume = "Documents";
        calendar = "daily";
        expiry = "5d";
      }
      {
        subvolume = "Music";
        calendar = "weekly";
        expiry = "3w";
      }
      {
        subvolume = "Pictures";
        calendar = "weekly";
        expiry = "3w";
      }
    ];
    */
  };

  # forward dns onto the tailnet
  networking.firewall.allowedTCPPorts = [ 8080 5001 ];
  networking.firewall.allowedUDPPorts = [ 5353 ];
  /*
  services.dnscrypt-proxy2.settings = {
    listen_addresses = [
      "100.110.70.18:53"
      "[fd7a:115c:a1e0::6a01:4614]:53"
      "127.0.0.1:53"
      "[::1]:53"
    ];
  };
  */

  # generic
  programs = {
  };

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", DRIVER=="pcieport", ATTR{power/wakeup}="disabled"
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
