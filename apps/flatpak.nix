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

    # Portals need an implementation; headless hosts fail eval with a bare enable.
    xdg.portal.enable = lib.mkIf config.nyx.desktop.enable (lib.mkDefault true);

    systemd.services.flatpak-repo = lib.mkIf cfg.addFlathub {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ pkgs.flatpak ];
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "30s";
      };
      script = ''
        # wait-online may be disabled, so DNS can lag this unit; skip the
        # network fetch once the remote exists and let Restart cover first boot
        flatpak remotes --columns=name | grep -qx flathub && exit 0
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      '';
    };

    nyx.persistence.home.directories = [
      ".var/app"
      ".local/share/flatpak"
    ];

    nyx.persistence.directories = [ "/var/lib/flatpak" ];
  };
}
