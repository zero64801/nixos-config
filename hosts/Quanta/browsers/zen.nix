{
  my.apps.zen = {
    addonPins = ./firefox-addons.json;

    preferences = {
      "browser.startup.page" = 3;
      "general.autoScroll" = true;
      "browser.ctrlTab.sortByRecentlyUsed" = true;
      "widget.gtk.rounded-bottom-corners.enabled" = true;

      "browser.uiCustomization.state" = builtins.toJSON {
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
      };
    };

    search = {
      force = true;
      default = "duckduckgo";
      engines.duckduckgo = {
        name = "DuckDuckGo";
        urls = [
          { template = "https://duckduckgo.com/?q={searchTerms}"; }
        ];
      };
    };

    profileSettings = {
      "zen.welcome-screen.seen" = true;
      "svg.context-properties.content.enabled" = true;
      "sidebar.revamp" = true;
      "sidebar.verticalTabs" = true;

      /*
      The 9070 XT (Navi 48) is newer than Firefox's built-in hardware-decode
      allowlist, so video silently falls back to software and stutters once KWin
      has to composite it in a window (fullscreen uses direct scanout and hides
      it). force-enabled bypasses the allowlist, and vainfo confirms the card
      decodes VP9/AV1/H264/HEVC. LIBVA_DRIVER_NAME pins libva to AMD (see
      graphics.nix).
      */
      "media.ffmpeg.vaapi.enabled" = true;
      "media.hardware-video-decoding.force-enabled" = true;
    };

    userChrome = ''
      /* Hide text in bookmarks in title bar */
      #PlacesToolbar toolbarbutton.bookmark-item > label.toolbarbutton-text {
        display: none !important;
      }
    '';
  };
}
