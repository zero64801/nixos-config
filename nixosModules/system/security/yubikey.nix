{
  pkgs,
  lib,
  config,
  ...
}: {
  options.nyx.security.yubikey.enable = lib.mkEnableOption "YubiKey support";
  config = lib.mkIf config.nyx.security.yubikey.enable {
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
      u2f.settings.authfile = "/etc/u2f_keys";
    };

    nyx.impermanence = lib.mkIf config.nyx.impermanence.enable {
      roots.${config.nyx.impermanence.mainPersistRoot} = {
        files = [
          "/etc/u2f_keys"
        ];
      };
    };
  };
}
