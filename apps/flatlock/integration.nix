{ config, lib, ... }:

/*
Kept separate from default.nix on purpose: the VM check imports the module standalone (imports = [ ./default.nix ]), so the module itself must not reference my.*, hm or other repo infrastructure.
This glue is auto imported into the full system config, where those options exist.
*/
let
  cfg = config.flatlock;
in
{
  config = lib.mkMerge [
    {
      hm.imports = [ ./_modules/home-manager.nix ];
      hm.flatlock.configRepoPath = lib.mkDefault config.my.flakePath;
      hm.flatlock.lockFileRelativePath = lib.mkDefault "hosts/${config.networking.hostName}/flatpak-user.lock";
    }

    (lib.mkIf cfg.enable {
      flatlock.configRepoPath = lib.mkDefault config.my.flakePath;

      # Portals need an implementation. Headless hosts fail eval with a bare enable.
      xdg.portal.enable = lib.mkIf config.my.desktop.enable (lib.mkDefault true);

      # owned by the flake user, the file lives in their git working tree
      systemd.tmpfiles.rules = lib.optionals (cfg.lockFile != null && cfg.configRepoPath != null) [
        "f ${cfg.configRepoPath}/${cfg.lockFileRelativePath} 0644 ${config.my.flake.user} users - {}"
      ];

      # user overrides outrank system overrides, binding the directory to the store keeps Flatseal from quietly loosening what the module declared
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
