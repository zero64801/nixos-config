{ config, lib, pkgs, ... }:

let
  user = config.nyx.flake.user;
  home = config.users.users.${user}.home;
  gamescopeRt = config.nyx.apps.gaming.gamescopeRt;
  library = "/mnt/vault/Games/SteamLibrary";
  protons = {
    dwproton = pkgs.dwproton-bin;
    proton-cachyos-v3 = pkgs.proton-cachyos-v3-bin;
  };
  # both hops: compattool dir is itself a symlink farm into pkg.src
  protonGrants =
    lib.concatMapStrings (pkg: "${pkg.steamcompattool}:ro;${pkg.src}:ro;")
      (lib.attrValues protons);
  appHome = "${home}/.var/app/com.valvesoftware.Steam";
  compatDir = "${appHome}/data/Steam/compatibilitytools.d";

  /*
  In-sandbox twin of the host nvrun (modules/graphics.nix): undoes the
  mesa pin from the override Environment and requests offload for one
  game. tmpfiles copy because launch options run inside the sandbox,
  where host binaries do not exist; resolved via the override PATH.
  */
  nvrunSandbox = pkgs.writeScript "steam-flatpak-nvrun" ''
    #!/bin/sh
    if [ "$#" -eq 0 ]; then
      echo "Usage: nvrun <command> [args...]" >&2
      exit 2
    fi
    unset __EGL_VENDOR_LIBRARY_FILENAMES
    export VK_LOADER_DRIVERS_DISABLE=""
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec "$@"
  '';
in
{
  flatlock.packages = [
    {
      appId = "com.valvesoftware.Steam";
      arch = "x86_64";
      branch = "stable";
    }
  ];

  # Steam's own extensions; the list merges with other flatpaks/*.nix files.
  flatlock.runtimes = [
    # branches must track the app runtime (org.freedesktop.Platform 25.08)
    # the old com.valvesoftware.Steam.Utility.gamescope ref is a deprecated empty stub, the VulkanLayer ref ships the actual binaries
    "org.freedesktop.Platform.VulkanLayer.MangoHud/x86_64/25.08"
    "org.freedesktop.Platform.VulkanLayer.gamescope/x86_64/25.08"
  ];

  # programs.steam normally ships these controller udev rules
  hardware.steam-hardware.enable = true;

  /*
  Hardened against the Flathub manifest, which grants device=all and all of
  /mnt, /media and /run/media. dri still covers /dev/nvidia*, input covers
  the pad. GameMode talk lets gamemoderun in launch options reach host
  gamemoded, so the x3d/scx hooks keep firing. Known costs: Steam Input
  virtual devices (uinput), bluetooth pads, Remote Play hosting and
  removable-drive libraries.

  filesystems starts from host:reset: negating a store-symlink path (the
  stylix theme grant) makes flatpak tmpfs-mask the target and rewrite the
  symlink chain into the sandbox, where persist=. keeps it, and the next
  home-manager generation turns it stale (bwrap: Can't make symlink).
  host:reset drops every inherited entry instead and the needed grants
  return explicitly. GTK_THEME unset: Steam is themed by adwsteamgtk.

  Environment re-pins EGL to mesa and disables the nvidia Vulkan ICD,
  the sandbox twin of the session ICD hiding in graphics.nix. nvrun
  undoes both per game. The GL/glvnd path aggregates every mounted GL
  extension and holds for any mesa flavor. PATH is a full replacement
  because flatpak cannot append: the app's baked PATH plus the gamescope
  extension and the app-home bin dir.

  MUST stay a user (hm) override: flatpak merges system global, system
  app, user global, user app, so only a user app override outranks the
  user-global theme grant.
  */
  hm.flatlock.overrides.settings."com.valvesoftware.Steam" = {
    Context = {
      devices = "!all;dri;input;";
      features = "!bluetooth;";
      filesystems =
        "!host:reset;xdg-config/MangoHud:ro;/run/udev:ro;xdg-run/speech-dispatcher:ro;xdg-run/app/com.discordapp.Discord:create;${gamescopeRt.socketPath};${library};${protonGrants}";
      unset-environment = "GTK_THEME;";
    };
    Environment = {
      __EGL_VENDOR_LIBRARY_FILENAMES = "/usr/lib/x86_64-linux-gnu/GL/glvnd/egl_vendor.d/50_mesa.json";
      VK_LOADER_DRIVERS_DISABLE = "nvidia_icd.json";
      PATH = "/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/gamescope/bin:${home}/bin";
    };
    "Session Bus Policy" = {
      "com.feralinteractive.GameMode" = "talk";
    };
    "System Bus Policy" = {
      "org.freedesktop.UDisks2" = "none";
    };
  };

  /*
  Protons are symlinks to the steamcompattool output, the same tmpfiles
  pattern gaming.nix uses for heroic; the generation roots the target and
  the override grants both hops read only. bwrap only materializes
  granted host paths that are themselves symlinks, so the stale-symlink
  abort above cannot trigger here. Dropping a proton leaves a dangling
  link; remove it by hand.
  */
  systemd.tmpfiles.rules =
    [
      "d ${compatDir} 0755 ${user} ${config.users.users.${user}.group} - -"
      "d ${appHome}/bin 0755 ${user} ${config.users.users.${user}.group} - -"
      "C+ ${appHome}/bin/nvrun 0755 ${user} ${config.users.users.${user}.group} - ${nvrunSandbox}"
      "C+ ${appHome}/bin/gamescope-rt 0755 ${user} ${config.users.users.${user}.group} - ${gamescopeRt.sandboxClient}"
    ]
    ++ lib.mapAttrsToList
      (name: pkg: "L+ ${compatDir}/${name} - - - - ${pkg.steamcompattool}")
      protons;
}
