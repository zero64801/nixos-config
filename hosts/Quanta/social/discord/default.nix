{
  nyx.apps.discord = {
    commandLineArgs = [ "--enable-blink-features=MiddleClickAutoscroll" ];

    localPlugins.MyServerRoles = ./local-plugins/myServerRoles;

    vencordConfig = {
      frameless = true;
      plugins = {
        betterSettings.enable = true;
        betterUploadButton.enable = true;
        clearUrls.enable = true;
        fakeNitro = {
          enable = true;
          transformCompoundSentence = true;
        };
        fixImagesQuality.enable = true;
        fixYoutubeEmbeds.enable = true;
        iLoveSpam.enable = true;
        loadingQuotes.enable = true;
        messageLinkEmbeds.enable = true;
        noBlockedMessages.enable = true;
        replaceGoogleSearch = {
          enable = true;
          customEngineName = "DuckDuckGo";
          customEngineUrl = "https://duckduckgo.com/";
        };
        silentTyping = {
          enable = true;
          chatContextMenu = true;
          enabledGlobally = false;
          chatIcon = true;
        };
        translate.enable = true;
        typingIndicator.enable = true;
        unindent.enable = true;
        voiceMessages.enable = true;
        youtubeAdblock.enable = true;
        messageLogger.enable = true;
      };
    };

    extraConfig.plugins = {
      AccountPanelServerProfile.enabled = false;
      MyServerRoles.enabled = true;
    };

    settings = {
      OPEN_ON_STARTUP = false;
      MINIMIZE_TO_TRAY = false;
    };
  };
}
