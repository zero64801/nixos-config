{ config, inputs, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.nyx.sops;
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  options.nyx.sops = {
    enable = mkEnableOption "sops-nix encrypted secrets (YubiKey-backed age identity)";
  };

  config = mkIf cfg.enable {
    sops = {
      defaultSopsFile = ./secrets.yaml;
      age = {
        keyFile = "${config.nyx.flakePath}/hosts/${config.nyx.flake.host}/secrets-identity.txt";
        generateKey = false;
        plugins = [ pkgs.age-plugin-yubikey ];
      };

      secrets = {
        "users/dx" = {
          neededForUsers = true;
        };
        u2f_keys = {
          mode = "0444";
        };
        luks = {
          mode = "0400";
        };
      };
    };

    environment.systemPackages = with pkgs; [
      age
      age-plugin-yubikey
      sops
    ];
  };
}
