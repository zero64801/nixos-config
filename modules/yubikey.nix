{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf;
in
{
  options.nyx.security.yubikey.enable = mkEnableOption "YubiKey support";

  config = mkIf config.nyx.security.yubikey.enable {
    services.pcscd.enable = true;

    environment.systemPackages = with pkgs; [
      yubioath-flutter
    ];

    programs.yubikey-touch-detector.enable = true;

    security.pam.u2f = {
      enable = true;
      settings = {
        authfile = "/etc/u2f_keys";
        cue = true;
      };
    };

    nyx.persistence.files = [ "/etc/u2f_keys" ];
  };
}
