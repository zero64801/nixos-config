{ pkgs, ... }:

let
  hostname = "Quanta";
  username = "dx";
in
{
  system.stateVersion = "25.11";
  networking.hostName = hostname;

  my = {
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

    pinning.enable = true;

    security = {
      yubikey.enable = true;
      touchGuard.enable = true;
      serviceAdminGroups = [ "wheel" ];
      restrictTrafficControl.enable = true;
    };

    apps = {
      zen.enable = true;
      discord.enable = true;
      vlessProxy = {
        enable = true;
        outboundFile = "/mnt/vault/secrets/sing-box/vless-outbound.json";
      };
      wgProxy = {
        enable = true;
        endpointFile = "/mnt/vault/secrets/sing-box/ivpn-wg-endpoint.json";
        tunnelDns = "172.16.0.1";
      };
      fish.enable = true;
      git = {
        enable = true;
        name = "zero64801";
        email = "zero64801@gmail.com";
        signing.enable = true;
        github.enable = true;
      };
      direnv.enable = true;
      confinedTerminal.enable = true;
      scx.enable = true;
      gaming = {
        enable = true;
        x3dCacheBias = true;

        steam = {
          enable = true;
          compatPackages = [
            pkgs.proton-cachyos-v3-bin
          ];
        };
      };
      llamaCpp = {
        enable = true;
        cuda = true;
      };
    };

    stylix = {
      enable = true;
      scheme = "rose-pine";
      polarity = "dark";
    };
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = username;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    settings = {
      server.use-ipv6 = false;
      publish = {
        disable-publishing = false;
        publish-addresses = true;
        publish-workstation = true;
        publish-aaaa-on-ipv4 = false;
      };
    };
  };

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };
}
