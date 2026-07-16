{
  flatlock.packages = [
    {
      appId = "com.github.Matoking.protontricks";
      arch = "x86_64";
      branch = "stable";
    }
  ];

  hm.flatlock.overrides.settings."com.github.Matoking.protontricks".Context.filesystems =
    "/mnt/vault/Games/Steam;";
}
