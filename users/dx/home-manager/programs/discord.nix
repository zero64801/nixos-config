{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.vesktop = {
    enable = true;

    vencord.settings = {
      autoUpdate = true;
      autoUpdateNotification = true;
      notifyAboutUpdates = true;

      plugins = {
        CopyFileContents.enabled = true;
        CopyUserURLs.enabled = true;
        FakeNitro.enabled = true;
        MessageLogger.enabled = true;
        ShowHiddenChannels.enabled = true;
        ShowHiddenThings.enabled = true;
        YoutubeAdblock.enabled = true;
      };
    };
  };
}
