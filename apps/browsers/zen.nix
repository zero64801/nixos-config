{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.zen;

  lock = x: {
    Value = x;
    Status = "locked";
  };

  commonPolicies = {
    AutofillAddressEnabled = true;
    AutofillCreditCardEnabled = false;
    DisableAppUpdate = true;
    DisableFeedbackCommands = true;
    DisableFirefoxStudies = true;
    DisablePocket = true;
    DisableTelemetry = true;
    DontCheckDefaultBrowser = true;
    NoDefaultBookmarks = true;
    OfferToSaveLogins = false;
    EnableTrackingProtection = {
      Value = true;
      Locked = true;
      Cryptomining = true;
      Fingerprinting = true;
    };
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
    UserMessaging.SkipOnboarding = true;
  };

  commonPreferences = {
    "browser.startup.page" = lock 3;
    "general.autoScroll" = lock true;
    "browser.ctrlTab.sortByRecentlyUsed" = lock true;
    "browser.contentblocking.category" = lock "strict";
    "dom.private-attribution.submission.enabled" = lock false;
    "browser.ml.chat.enabled" = lock false;
    "toolkit.legacyUserProfileCustomizations.stylesheets" = lock true;
    "widget.gtk.rounded-bottom-corners.enabled" = lock true;
  };

  mkExtensionPolicy = extensions: {
    "*" = {
      installation_mode = "blocked";
      blocked_install_message = "Install extensions through Nix.";
    };
  } // builtins.listToAttrs (
    builtins.map (e:
      let id = e.passthru.addonId;
      in {
        name = id;
        value = {
          install_url = "file://${e}/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${id}.xpi";
          installation_mode = "force_installed";
          private_browsing = true;
        };
      }
    ) extensions
  );

  commonUserChrome = ''
    /* Hide text in bookmarks in title bar */
    #PlacesToolbar toolbarbutton.bookmark-item > label.toolbarbutton-text {
      display: none !important;
    }
  '';
in
{
  options.nyx.apps.zen.enable = lib.mkEnableOption "Zen Browser";

  config = lib.mkIf cfg.enable {
    hm = {
      imports = [
        inputs.zen-browser.homeModules.beta
      ];

      programs.zen-browser = {
        enable = true;

        policies = commonPolicies // {
        Preferences = commonPreferences // {
          "browser.uiCustomization.state" = lock (
            builtins.toJSON {
              placements = {
                widget-overflow-fixed-list = [ ];
                unified-extensions-area = [
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
                TabsToolbar = [ "tabbrowser-tabs" ];
                PersonalToolbar = [ "import-button" ];
              };
              seen = [
                "addon_darkreader_org-browser-action"
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
        };

        ExtensionSettings = mkExtensionPolicy (
          with inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}; [
            darkreader
            return-youtube-dislikes
            ublock-origin
            bitwarden
          ]
        );
      };

      profiles.default = {
        name = "Default";
        search = {
          force = true;
          default = "startpage";
          engines = {
            startpage = {
              name = "Startpage";
              urls = [
                { template = "https://www.startpage.com/sp/search?query={searchTerms}"; }
              ];
            };
          };
        };
        settings = {
          "zen.welcome-screen.seen" = true;
          "svg.context-properties.content.enabled" = true;
          "sidebar.revamp" = true;
          "sidebar.verticalTabs" = true;
        };
        userChrome = commonUserChrome;
      };

      nativeMessagingHosts = [ ];
      };
    };

    nyx.persistence.home.directories = [
      ".zen/default/cookies.sqlite"
    ];
  };
}
