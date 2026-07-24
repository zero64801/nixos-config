{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionals types;

  dlopenLibs = [
    pkgs.glibc
    pkgs.libglvnd
    pkgs.vulkan-loader
  ];

  /*
  Opt-in PRIME render offload onto the nvidia card. The session-wide ICD
  hiding keeps every app off the card by default; this wrapper re-exposes
  the ICDs and requests offload for one command, e.g. `nvrun steam` or
  `nvrun %command%` in Steam launch options.
  */
  nvrun = pkgs.writeShellScriptBin "nvrun" ''
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

  # Mirror of nvrun for nvidia-backend hosts: pins one command to the AMD/mesa stack.
  amdrun = pkgs.writeShellScriptBin "amdrun" ''
    if [ "$#" -eq 0 ]; then
      echo "Usage: amdrun <command> [args...]" >&2
      exit 2
    fi
    export VK_LOADER_DRIVERS_DISABLE="nvidia_icd.json"
    export __EGL_VENDOR_LIBRARY_FILENAMES="/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json"
    export DRI_PRIME=1
    unset __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME __VK_LAYER_NV_optimus
    exec "$@"
  '';

  /*
  Zero-copy direct output: a gamescope DRM session owning the secondary GPU's
  own connector, bypassing the desktop compositor entirely. Needs a monitor
  cabled to that card; flip the monitor input to play, flip back on exit.
  The game runs under gamemoderun so the scx/x3d gamemode hooks still fire.
  Extra gamescope flags go in GAMESCOPE_OPTS.
  */
  mkScopeWrapper = name: env: pkgs.writeShellScriptBin name ''
    if [ "$#" -eq 0 ]; then
      echo "Usage: ${name} <command> [args...]" >&2
      echo "Runs the command fullscreen on the secondary GPU's own monitor output." >&2
      exit 2
    fi
    ${env}
    exec ${lib.getExe pkgs.gamescope} --backend drm --fullscreen ''${GAMESCOPE_OPTS:-} -- ${lib.getExe' pkgs.gamemode "gamemoderun"} "$@"
  '';

  nvscope = mkScopeWrapper "nvscope" ''
    export VK_DRIVER_FILES="/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json"
    export __EGL_VENDOR_LIBRARY_FILENAMES="/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json"
    export VK_LOADER_DRIVERS_DISABLE=""
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
  '';

  amdscope = mkScopeWrapper "amdscope" ''
    export VK_DRIVER_FILES="/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
    export VK_LOADER_DRIVERS_DISABLE=""
    export __EGL_VENDOR_LIBRARY_FILENAMES="/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json"
    export __GLX_VENDOR_LIBRARY_NAME=mesa
  '';

  cfg = config.nyx.graphics;

  amdEnabled = cfg.backend == "amd" || cfg.amd.enable;
  nvidiaEnabled = cfg.backend == "nvidia" || cfg.nvidia.enable;
in
{
  options.nyx.graphics = {
    enable = mkEnableOption "graphics configuration";

    backend = mkOption {
      type = types.enum [ "amd" "nvidia" ];
      default = "amd";
      description = "Primary display graphics backend.";
    };

    amd = {
      enable = mkOption {
        type = types.bool;
        default = cfg.backend == "amd";
        description = "Install AMD drivers and userland. Defaults to true when backend is amd.";
      };
    };

    nvidia = {
      enable = mkEnableOption "NVIDIA drivers";

      open = mkOption {
        type = types.bool;
        default = true;
        description = "Use the NVIDIA open kernel modules (Turing+ cards).";
      };

      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Override the NVIDIA driver package.";
      };

      drm.enable = mkEnableOption ''
        nvidia_drm KMS on a non-nvidia backend, enabling PRIME render offload
        for host apps via the nvrun wrapper while the card stays switchable
        to vfio (apps launched through nvrun die on a switch)
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      hardware.graphics = {
        enable = true;
        enable32Bit = true;
      };

      programs.nix-ld = {
        enable = true;
        libraries = dlopenLibs;
      };

      services.xserver.videoDrivers =
        optionals amdEnabled [ "amdgpu" ]
        ++ optionals nvidiaEnabled [ "nvidia" ];

      environment.systemPackages = [
        (pkgs.btop.override {
          cudaSupport = nvidiaEnabled;
          rocmSupport = amdEnabled;
        })
      ];
    }

    (mkIf amdEnabled {
      environment.systemPackages = [ pkgs.radeontop ];
    })

    (mkIf nvidiaEnabled {
      hardware.nvidia = {
        modesetting.enable = cfg.backend == "nvidia";
        open = cfg.nvidia.open;
        nvidiaSettings = cfg.backend == "nvidia";
        powerManagement.enable = false;
        package =
          if cfg.nvidia.package != null
          then cfg.nvidia.package
          else config.boot.kernelPackages.nvidiaPackages.latest;
      };

      environment.systemPackages =
        [ pkgs.nvtopPackages.nvidia ]
        ++ lib.optionals cfg.nvidia.drm.enable [ nvrun nvscope ]
        ++ lib.optionals (cfg.backend == "nvidia" && cfg.amd.enable) [ amdrun amdscope ];

      boot.blacklistedKernelModules =
        [ "nouveau" ]
        ++ lib.optional (cfg.backend != "nvidia" && !cfg.nvidia.drm.enable) "nvidia_drm";

      boot.kernelParams =
        lib.optional (cfg.backend != "nvidia" && !cfg.nvidia.drm.enable) "modprobe.blacklist=nvidia_drm"
        # fbdev=0 keeps the console framebuffer off the card so vfio unbind stays clean.
        ++ lib.optionals (cfg.backend != "nvidia" && cfg.nvidia.drm.enable) [
          "nvidia_drm.modeset=1"
          "nvidia_drm.fbdev=0"
        ];

      # Nothing else loads nvidia_drm on a Wayland-only host (X11 configs load it via the DDX).
      boot.kernelModules =
        lib.optionals (cfg.backend != "nvidia" && cfg.nvidia.drm.enable) [ "nvidia_drm" ];

      boot.extraModprobeConfig =
        lib.optionalString (cfg.backend != "nvidia" && !cfg.nvidia.drm.enable) ''
          install nvidia_drm /bin/true
        '';

      # Keep desktop apps off the secondary card entirely: incidental EGL/Vulkan enumeration
      # leaves device fds open, which gpu-switch then has to fuser -k (visible as app flashes).
      # CUDA, ROCm and NVENC bypass both loaders, so compute is unaffected either way.
      environment.sessionVariables =
        if cfg.backend != "nvidia" then
          {
            __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
            VK_LOADER_DRIVERS_DISABLE = "nvidia_icd.json";
            # Pin VA-API to the AMD card so no app can load nvidia_drv_video.so on the
            # secondary node (its EGL is hidden above, so that path only ever fails).
            LIBVA_DRIVER_NAME = "radeonsi";
          }
        else
          lib.optionalAttrs cfg.amd.enable {
            __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json";
            VK_LOADER_DRIVERS_DISABLE = "radeon_icd*";
          };
    })
  ]);
}
