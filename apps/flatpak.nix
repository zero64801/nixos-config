{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.flatpak;
in
{
  options.nyx.apps.flatpak = {
    enable = lib.mkEnableOption "Flatpak support";

    addFlathub = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add the Flathub remote automatically.";
      example = false;
    };
  };

  config = lib.mkIf cfg.enable {
    services.flatpak.enable = true;

    xdg.portal.enable = true;

    systemd.services.flatpak-repo = lib.mkIf cfg.addFlathub {
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.flatpak ];
      script = ''
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      '';
    };
  };
}
