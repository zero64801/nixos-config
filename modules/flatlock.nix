{ config, lib, ... }:

let
  cfg = config.flatlock;
in
{
  config = lib.mkMerge [
    {
      hm.imports = [ ../apps/flatlock/_modules/home-manager.nix ];
      hm.flatlock.configRepoPath = lib.mkDefault config.my.flakePath;
      hm.flatlock.lockFileRelativePath = lib.mkDefault "hosts/${config.networking.hostName}/flatpak-user.lock";
    }

    (lib.mkIf cfg.enable {
      flatlock.configRepoPath = lib.mkDefault config.my.flakePath;
      flatlock.lockFileRelativePath = lib.mkDefault "hosts/${config.networking.hostName}/flatpak.lock";

      # Headless hosts fail eval with a bare portal enable because portals need an implementation.
      xdg.portal.enable = lib.mkIf config.my.desktop.enable (lib.mkDefault true);

      systemd.tmpfiles.rules = lib.optionals (cfg.lockFile != null && cfg.configRepoPath != null) [
        "f ${cfg.configRepoPath}/${cfg.lockFileRelativePath} 0644 ${config.my.flake.user} users - {}"
      ];

      # User overrides outrank system overrides, so binding the directory to the store keeps Flatseal from quietly loosening what the module declared.
      hm.xdg.dataFile = lib.mkIf cfg.strictOverrides {
        "flatpak/overrides".source = cfg.overridesPackage;
      };

      my.persistence.directories = [
        "/var/lib/flatpak"
        "/var/lib/flatlock"
      ];

      my.persistence.home.directories = [
        ".var/app"
        ".local/share/flatpak"
        ".local/state/flatlock"
      ];
    })
  ];
}
