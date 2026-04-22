{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf optional;
  sopsEnabled = config.nyx.sops.enable or false;
  authfilePath =
    if sopsEnabled
    then config.sops.secrets.u2f_keys.path
    else "/etc/u2f_keys";
in
{
  options.nyx.security.yubikey.enable = mkEnableOption "YubiKey support";

  config = mkIf config.nyx.security.yubikey.enable {
    services.pcscd.enable = true;

    environment.systemPackages = with pkgs; [
      yubioath-flutter
    ];

    programs.yubikey-touch-detector.enable = true;

    security.pam = {
      services = {
        login.u2fAuth = true;
        sudo.u2fAuth = true;
        polkit-1.u2fAuth = true;
      };
      u2f.settings.authfile = authfilePath;
    };

    nyx.persistence.files = optional (!sopsEnabled) "/etc/u2f_keys";
  };
}
