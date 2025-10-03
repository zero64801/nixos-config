{
  lib,
  config,
  pkgs,
  ...
}:
{
  options.nyx.programs.flatpak = {
    enable = lib.mkEnableOption "Flatpak support";

    addFlathub = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add the Flathub remote automatically.";
      example = false;
    };
  };

  config = lib.mkIf config.nyx.programs.flatpak.enable {
    # Enable the core Flatpak service
    services.flatpak.enable = true;

    # Enable XDG portals for desktop integration (file pickers, etc.)
    # This is crucial for a good desktop experience.
    xdg.portal.enable = true;

    systemd.services.flatpak-repo = {
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.flatpak ];
      script = ''
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      '';
    };
  };
}
