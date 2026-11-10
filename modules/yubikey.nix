{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.security.yubikey;
  keyFile = "/etc/u2f_keys";
in
{
  options.my.security.yubikey = {
    enable = mkEnableOption "YubiKey support";

    rootNeedsKey = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Accept only the security key for sudo, su and polkit, which covers pkexec and run0.
        A password typed into a fake prompt then cannot be replayed for root. Losing every
        registered key means booting a generation from before this was turned on.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.pcscd.enable = true;

    environment.systemPackages = mkIf config.my.desktop.enable [
      pkgs.yubioath-flutter
    ];

    programs.yubikey-touch-detector.enable = !config.my.security.touchGuard.enable;

    security.pam.u2f = {
      enable = true;
      settings = {
        authfile = keyFile;
        cue = true;
      };
    };

    security.pam.services = mkIf cfg.rootNeedsKey (
      lib.genAttrs [ "sudo" "su" "polkit-1" ] (_: {
        unixAuth = false;
      })
    );

    my.persistence.files = lib.optional (config.security.pam.u2f.settings.authfile == keyFile) keyFile;
  };
}
