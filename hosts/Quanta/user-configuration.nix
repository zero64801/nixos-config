{
  config,
  lib,
  pkgs,
  dconf,
  ...
}: let
  packages = lib.attrValues {
    inherit (pkgs) foot;
    # from internal overlay
    inherit (pkgs) mpv-wrapped;
  };
in {
  users.users."dx" = {
    inherit packages;
    extraGroups = [];
  };

  services.pcscd.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  home-manager.users."dx" = {
    imports = [ ./apps ];
  
    programs.git = {
      enable = true;

      userName = "dx";
      userEmail = "dx@example.com";

      extraConfig = {
        safe.directory = "/system-flake";
      };
    };

    gtk = {
      enable = true;
      
      theme = {
        name = "Orchis-Purple-Dark-Compact";
        package = pkgs.orchis-theme;
      };
      
      iconTheme = {
        name = "Tela-purple-dark";
        package = pkgs.tela-icon-theme;
      };
    };
  
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

      "org/gnome/shell/extensions/user-theme".name = "Orchis-Purple-Dark-Compact";

      "org/gnome/desktop/interface".color-scheme = "prefer-dark";
      "org/gnome/desktop/background".picture-uri-dark = "file:///home/dx/Pictures/Wallpapers/wp3.jpg";

      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close"; # minimize,maximize,close
      };

      "org/gnome/shell/extensions/dash-to-dock" = {
        show-mounts = false;
        show-trash = false;
      };

      "org/gnome/shell/extensions/caffeine" = {
        toggle-state = true;
        restore-state = true;
      };

      "org/gnome/settings-daemon/plugins/media-keys" = {
        custom-keybindings = [
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ddc-dp/"
          "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ddc-hdmi/"
        ];
      };

      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ddc-dp" = {
        name = "Switch monitor -> DisplayPort";
        command = "${pkgs.ddcutil}/bin/ddcutil setvcp 60 3";
        binding = "<Control><Shift>F1";
      };

      "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ddc-hdmi" = {
        name = "Switch monitor -> HDMI";
        command = "${pkgs.ddcutil}/bin/ddcutil setvcp 60 1";
        binding = "<Control><Shift>F2";
      };
    };
  };
}
