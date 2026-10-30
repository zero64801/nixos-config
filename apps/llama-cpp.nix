{ config, lib, pkgs, ... }:

let
  cfg = config.my.apps.llamaCpp;
in
{
  options.my.apps.llamaCpp = {
    enable = lib.mkEnableOption "Llama-cpp app";

    vulkan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build llama-cpp with Vulkan support.";
    };

    cuda = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build llama-cpp with CUDA support.";
    };

    rocm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build llama-cpp with ROCm support.";
    };

    rpc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build llama-cpp with RPC support.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.llama-cpp.override (
        lib.optionalAttrs cfg.cuda { cudaSupport = true; }
        // lib.optionalAttrs cfg.vulkan { vulkanSupport = true; }
        // lib.optionalAttrs cfg.rocm { rocmSupport = true; }
        // lib.optionalAttrs cfg.rpc { rpcSupport = true; }
      );
      defaultText = lib.literalExpression "pkgs.llama-cpp.override { ... }";
      description = "llama-cpp package built with the selected backends.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open TCP 3000 for a LAN-reachable llama-server.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [
      3000
    ];

    nix.settings = lib.mkIf cfg.cuda {
      substituters = [ "https://cache.nixos-cuda.org" ];
      trusted-public-keys = [
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
    };
  };
}
