{ pkgs, ... }:

let
  hostname = "Quanta";
  username = "dx";
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
      serviceAdminGroups = [ "wheel" ];
    };

    apps = {
      zen.enable = true;
      discord.enable = true;
      vlessProxy = {
        enable = true;
        # on vault so a root factory reset keeps the credentials
        outboundFile = "/mnt/vault/secrets/sing-box/vless-outbound.json";
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
      zeditor.enable = true;
      scx.enable = true;
      gaming = {
        enable = true;
        x3dCacheBias = true;

        # Confined in hosts/Quanta/confine/steam.nix.
        steam = {
          enable = true;
          compatPackages = [
            pkgs.dwproton-bin
            pkgs.proton-cachyos-v3-bin
          ];
        };
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
}
