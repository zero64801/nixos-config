{
  config,
  lib,
  ...
}:
{
  options.nyx.graphics.nvidia = {
    enable = lib.mkEnableOption "nVidia graphics";
    hybrid = {
      enable = lib.mkEnableOption "optimus prime";
      igpu = {
        vendor = lib.mkOption {
          type = lib.types.enum [
            "amd"
            "intel"
          ];
          default = "amd";
        };
        port = lib.mkOption {
          default = "";
          description = "Bus Port of igpu";
        };
      };
      dgpu.port = lib.mkOption {
        default = "";
        description = "Bus Port of dgpu";
      };
    };
  };

  config =
    let
      cfg = config.nyx.graphics.nvidia;
    in
    lib.mkIf (cfg.enable && config.nyx.graphics.enable) {
      nix.settings = {
        extra-substituters = [
          "https://cuda-maintainers.cachix.org"
          "https://aseipp-nix-cache.global.ssl.fastly.net"
        ];
        extra-trusted-public-keys = [
          "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
        ];
      };
      services.xserver.videoDrivers =
        let
          order = if config.nyx.graphics.primary == "nvidia" then 100 else 200;
        in
        lib.mkOrder order [ "nvidia" ];

      boot.kernelModules = [
        "nvidia"
        "nvidia_modeset"
        "nvidia_uvm"
        "nvidia_drm"
      ];

      hardware.nvidia = {
        modesetting.enable = true;
        dynamicBoost.enable = false;

        powerManagement = {
          enable = false;
          finegrained = cfg.hybrid.enable;
        };

        # Use the NVidia open source kernel module (not to be confused with the
        # independent third-party "nouveau" open source driver).
        open = true;

        nvidiaSettings = true;
        package = config.boot.kernelPackages.nvidiaPackages.latest;

        prime = lib.mkIf cfg.hybrid.enable {
          offload = {
            enable = true;
            enableOffloadCmd = true;
          };

          amdgpuBusId = lib.mkIf (cfg.hybrid.igpu.vendor == "amd") cfg.hybrid.igpu.port;
          intelBusId = lib.mkIf (cfg.hybrid.igpu.vendor == "intel") cfg.hybrid.igpu.port;
          nvidiaBusId = cfg.hybrid.dgpu.port;
        };
      };
    };
}
