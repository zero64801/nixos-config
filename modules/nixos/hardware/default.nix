{ lib, config, ... }:

{
  imports = [
    ./amd.nix
    ./nvidia.nix
  ];

  options.nyx.graphics.enable = lib.mkEnableOption "graphics support";

  config = lib.mkIf config.nyx.graphics.enable {
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };
  };
}
