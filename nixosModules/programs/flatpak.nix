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

    # Conditionally add the Flathub remote using a systemd service.
    # This is a robust, declarative way to ensure the remote is present.
    systemd.services.flatpak-repo = lib.mkIf config.nyx.programs.flatpak.addFlathub {
      description = "Add Flathub remote for Flatpak";
      wantedBy = [ "multi-user.target" ];
      # Ensure this service runs after the network is up
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Provide the flatpak binary to the script's PATH
      path = [ pkgs.flatpak ];
      # The script itself is idempotent due to `--if-not-exists`
      script = ''
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      '';
      # This service is simple and only needs to run once.
      serviceConfig.Type = "oneshot";
    };
  };
}
