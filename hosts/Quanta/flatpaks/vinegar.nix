{
  flatlock.packages = [
    {
      appId = "org.vinegarhq.Vinegar";
      arch = "x86_64";
      branch = "stable";
    }
  ];

  hm.flatlock.overrides.settings."org.vinegarhq.Vinegar".Environment.__EGL_VENDOR_LIBRARY_FILENAMES =
    "/usr/lib/x86_64-linux-gnu/GL/glvnd/egl_vendor.d/50_mesa.json";
}
