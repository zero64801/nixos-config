{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionals types;

  dlopenLibs = [
    pkgs.glibc
    pkgs.libglvnd
    pkgs.vulkan-loader
  ];

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

      environment.systemPackages = [ pkgs.nvtopPackages.nvidia ];

      boot.blacklistedKernelModules =
        [ "nouveau" ]
        ++ lib.optional (cfg.backend != "nvidia") "nvidia_drm";

      boot.kernelParams =
        lib.optional (cfg.backend != "nvidia") "modprobe.blacklist=nvidia_drm";

      boot.extraModprobeConfig =
        lib.optionalString (cfg.backend != "nvidia") ''
          install nvidia_drm /bin/true
        '';
    })
  ]);
}
