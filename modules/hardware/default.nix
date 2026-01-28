{
  lib,
  config,
  ...
}:
let
  cfg = config.nyx.graphics;
in
{
  imports = [
    ./amd.nix
    ./nvidia.nix
  ];

  options.nyx.graphics = {
    enable = lib.mkEnableOption "graphics support";

    primary = lib.mkOption {
      type = lib.types.enum [
        "amd"
        "nvidia"
      ];
      default = "amd";
      description = "Primary GPU for display output. This controls the ordering of videoDrivers.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };
  };
}
