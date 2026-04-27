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

    # When cuda is on, pull cached pre-built binaries from the CUDA cache
    # (saves hours of local compile). Lists merge with whatever other
    # modules contribute to nix.settings.
    #
    # Note: on the FIRST rebuild that enables cuda, the cache isn't in
    # /etc/nix/nix.conf yet (activation runs after the build), so the
    # build runs locally. Bootstrap by running the first-time switch
    # with these flags, then future rebuilds use the cache automatically:
    #
    #   sudo nixos-rebuild switch --flake ~/nixos#<host> \
    #     --option extra-substituters "https://cache.nixos-cuda.org" \
    #     --option extra-trusted-public-keys \
    #       "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    nix.settings = lib.mkIf cfg.cuda {
      substituters = [ "https://cache.nixos-cuda.org" ];
      trusted-public-keys = [
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
    };
  };
}
