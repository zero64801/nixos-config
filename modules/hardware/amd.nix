{
  pkgs,
  config,
  lib,
  ...
}:
{
  options.nyx.graphics.amd.enable = lib.mkEnableOption "amd graphics";

  config = lib.mkIf (config.nyx.graphics.amd.enable && config.nyx.graphics.enable) {
    environment.systemPackages = with pkgs; [
      radeontop
      btop-rocm
    ];
    hardware.graphics = {
      extraPackages = with pkgs; [
        rocmPackages.clr.icd
        libva-vdpau-driver
        libvdpau-va-gl
      ];
    };

    services.xserver.videoDrivers =
      let
        order = if config.nyx.graphics.primary == "amd" then 100 else 200;
      in
      lib.mkOrder order [ "amdgpu" ];

    # amd hip workaround
    systemd.tmpfiles.rules = [
      "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
    ];
    environment.sessionVariables.RADV_PERFTEST = "video_decode";
  };
}
