{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf;
in
{
  options.my.security.yubikey.enable = mkEnableOption "YubiKey support";

  config = mkIf config.my.security.yubikey.enable {
    services.pcscd.enable = true;

    environment.systemPackages = mkIf config.my.desktop.enable [
      pkgs.yubioath-flutter
    ];

    programs.yubikey-touch-detector.enable = true;

    security.pam.u2f = {
      enable = true;
      settings = {
        authfile = "/etc/u2f_keys";
        cue = true;
      };
    };

    my.persistence.files = [ "/etc/u2f_keys" ];
  };
}
