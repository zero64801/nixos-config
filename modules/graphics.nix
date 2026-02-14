{ pkgs, lib, config, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  dlopenLibs = [
    pkgs.glibc
    pkgs.libglvnd
    pkgs.vulkan-loader
  ];

  cfg = config.nyx.graphics;
in
{
  options.nyx.graphics = {
    enable = mkEnableOption "graphics configuration";

    backend = mkOption {
      type = types.enum [ "amd" "nvidia" "intel" ];
      default = "amd";
      description = "The graphics backend to use";
    };
  };

  config = mkIf cfg.enable {
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    programs.nix-ld = {
      enable = true;
      libraries = dlopenLibs;
    };
  };
}
