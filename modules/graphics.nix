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
      enable = mkEnableOption "NVIDIA drivers (secondary GPU for compute / VFIO passthrough)";

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
    }

    (mkIf amdEnabled {
      environment.systemPackages = [ pkgs.btop-rocm ];
    })

    (mkIf nvidiaEnabled {
      hardware.nvidia = {
        modesetting.enable = true;
        open = cfg.nvidia.open;
        nvidiaSettings = true;
        powerManagement.enable = false;
        package =
          if cfg.nvidia.package != null
          then cfg.nvidia.package
          else config.boot.kernelPackages.nvidiaPackages.stable;
      };

      environment.systemPackages = [ pkgs.nvtopPackages.nvidia ];

      boot.blacklistedKernelModules = [ "nouveau" ];
    })
  ]);
}
