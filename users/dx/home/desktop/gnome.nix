{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  wallpaperPath =
    if builtins.pathExists ./wallpapers/default.jpg then
      "${./wallpapers/default.jpg}"
    else if builtins.pathExists ./wallpapers/default.png then
      "${./wallpapers/default.png}"
    else
      null;
in
{
  config = lib.mkMerge [
    (lib.mkIf
      (osConfig.services.desktopManager.gnome.enable || osConfig.services.desktopManager.cosmic.enable)
      {
        dconf.settings = {
          "org/gnome/desktop/wm/preferences" = {
            button-layout = "appmenu:minimize,maximize,close";
          };
        };
      }
    )

    (lib.mkIf osConfig.services.desktopManager.gnome.enable {
      dconf.settings = {
        "org/gnome/shell" = {
          disable-user-extensions = false;
          enabled-extensions = with pkgs.gnomeExtensions; [
            user-themes.extensionUuid
            appindicator.extensionUuid
            dash-to-dock.extensionUuid
            clipboard-indicator.extensionUuid
            hide-activities-button.extensionUuid
            window-is-ready-remover.extensionUuid
            caffeine.extensionUuid
            overview-background.extensionUuid
          ];
          favorite-apps = [
            "firefox.desktop"
            "org.gnome.Terminal.desktop"
            "org.gnome.Nautilus.desktop"
          ];
        };
        "org/gnome/shell/extensions/user-theme" = {
          name = "Orchis-Dark-Compact";
        };
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
        };
        "org/gnome/desktop/background" = lib.mkIf (wallpaperPath != null) {
          picture-uri-dark = "file://${wallpaperPath}";
        };
        "org/gnome/shell/extensions/dash-to-dock" = {
          show-mounts = false;
          show-trash = false;
        };
        "org/gnome/shell/extensions/caffeine" = {
          toggle-state = true;
          restore-state = true;
        };
      };
    })
  ];
}
