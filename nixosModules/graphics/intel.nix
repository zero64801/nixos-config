{
  pkgs,
  lib,
  config,
  ...
}: let
  inherit (lib) mkEnableOption mkIf getExe;
  cfg = config.nyx.graphics.intel;
in {
  options.nyx.graphics.intel = {
    enable = mkEnableOption "intel graphics";
  };
  config = mkIf (cfg.enable && config.nyx.graphics.enable) {
    environment.systemPackages = with pkgs; [ btop ];

    hardware.graphics.extraPackages = [
      pkgs.intel-media-driver
      pkgs.vpl-gpu-rt
      pkgs.intel-vaapi-driver
      pkgs.libvdpau-va-gl
      pkgs.intel-ocl
    ];

    security.wrappers.btop = {
      owner = "root";
      group = "root";
      source = getExe pkgs.btop;
      capabilities = "cap_perfmon+ep";
    };

    environment.sessionVariables.ANV_VIDEO_DECODE = 1;
  };
}
