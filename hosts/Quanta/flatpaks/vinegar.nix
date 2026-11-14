{
  flatlock.packages = [
    {
      appId = "org.vinegarhq.Vinegar";
      arch = "x86_64";
      branch = "stable";
    }
  ];

  my.apps.studioBroker = {
    enable = true;
    lockFolders = [ ".var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/users/dx/Downloads" ];
  };

  hm.flatlock.overrides.settings."org.vinegarhq.Vinegar".Environment.__EGL_VENDOR_LIBRARY_FILENAMES =
    "/usr/lib/x86_64-linux-gnu/GL/glvnd/egl_vendor.d/50_mesa.json";
}
