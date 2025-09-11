{
  config,
  pkgs,
  ...
}:
{
  programs.librewolf = {
    enable = true;
    policies = {
      DisableFirefoxStudies = true;
      DisableTelemetry = true;
      DisplayBookmarksToolbar = "never";
      FirefoxHome = {
        Pocket = false;
        Snippets = false;
        SponsoredTopSites = false;
      };
      FirefoxSuggest = {
        SponsoredSuggestions = false;
        ImproveSuggest = false;
      };
      PasswordManagerEnabled = false;
      UserMessaging = {
        SkipOnboarding = true;
      };

      Preferences =
        let
          lock = x: {
            Value = x;
            Status = "locked";
          };
        in
        {
          # general
          "browser.startup.page" = lock 3; # restore prev session
          "general.autoScroll" = lock true;
          "browser.ctrlTab.sortByRecentlyUsed" = lock true;
          "browser.contentblocking.category" = lock "strict";
          "dom.private-attribution.submission.enabled" = lock false;

          # ui layout
          "browser.uiCustomization.state" = lock (
            builtins.toJSON {
              placements = {
                widget-overflow-fixed-list = [ ];
                unified-extensions-area = [
                  "_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action"
                  "addon_darkreader_org-browser-action"
                  "ublock0_raymondhill_net-browser-action"
                ];
                nav-bar = [
                  "sidebar-button"
                  "back-button"
                  "forward-button"
                  "stop-reload-button"
                  "personal-bookmarks"
                  "customizableui-special-spring1"
                  "urlbar-container"
                  "customizableui-special-spring2"
                  "downloads-button"
                  "unified-extensions-button"
                ];
                toolbar-menubar = [ "menubar-items" ];
                TabsToolbar = [
                  "tabbrowser-tabs"
                ];
                PersonalToolbar = [ "import-button" ];
              };
              seen = [
                "addon_darkreader_org-browser-action"
                "_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action"
                "ublock0_raymondhill_net-browser-action"
                "developer-button"
              ];
              dirtyAreaCache = [
                "nav-bar"
                "unified-extensions-area"
                "PersonalToolbar"
                "toolbar-menubar"
                "TabsToolbar"
              ];
              currentVersion = 20;
              newElementCount = 5;
            }
          );

          # firefox-gnome-theme
          "toolkit.legacyUserProfileCustomizations.stylesheets" = lock true;
          "widget.gtk.rounded-bottom-corners.enabled" = lock true;
        };

      ExtensionSettings =
        {
          "*" = {
            installation_mode = "blocked";
            blocked_install_message = "Install extensions through Nix.";
          };
        }
        // (
          let
            extensions = with pkgs.nur.repos.rycee.firefox-addons; [
              darkreader
              tweaks-for-youtube
              return-youtube-dislikes
              ublock-origin
              user-agent-string-switcher
              consent-o-matic
              bitwarden
            ];
            extensionsPolicy = builtins.listToAttrs (
              builtins.map (
                e:
                let
                  id = e.passthru.addonId;
                in
                {
                  name = id;
                  value = {
                    install_url = "file://${e}/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${id}.xpi";
                    installation_mode = "force_installed";
                    private_browsing = true;
                  };
                }
              ) extensions
            );
          in
          extensionsPolicy
        );
    };
    profiles.default = {
      name = "Default";
      search.default = "ddg";
      search.force = true;
      settings = {
        # required for f-g-t; can't be set through enterprise policies
        "svg.context-properties.content.enabled" = true;

        # for some reason can't be set from enterprise policy despite being part of firefox itself???
        "sidebar.revamp" = true;
        "sidebar.verticalTabs" = true;
      };
      userChrome = ''
        /* Hide text in bookmarks in title bar */
        #PlacesToolbar toolbarbutton.bookmark-item > label.toolbarbutton-text {
          display: none !important;
        }
      '';
    };
    nativeMessagingHosts = with pkgs; [
      keepassxc
    ];
  };
}

