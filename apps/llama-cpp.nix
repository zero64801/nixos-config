{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.llama-cpp;
in
{
  options.nyx.apps.llama-cpp = {
    enable = lib.mkEnableOption "Llama-cpp app";

    vulkan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable vulkan support.";
      example = false;
    };

    cuda = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable cuda support.";
      example = false;
    };

    rocm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable rocm support.";
      example = false;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      (llama-cpp.override {
        vulkanSupport = cfg.vulkan;
        cudaSupport = cfg.cuda;
        rocmSupport = cfg.rocm;
      })
    ];

    networking.firewall.allowedTCPPorts = [
      3000
    ];
  };
}
