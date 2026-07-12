{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.llamaCpp;
in
{
  options.nyx.apps.llamaCpp = {
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

    /*
    When cuda is on, pull cached pre-built binaries from the CUDA cache
    (saves hours of local compile). Lists merge with whatever other
    modules contribute to nix.settings.

    Note: on the FIRST rebuild that enables cuda, the cache isn't in
    /etc/nix/nix.conf yet (activation runs after the build), so the
    build runs locally. Bootstrap by running the first-time switch
    with these flags, then future rebuilds use the cache automatically:

      sudo nixos-rebuild switch --flake ~/nixos#<host> \
        --option extra-substituters "https://cache.nixos-cuda.org" \
        --option extra-trusted-public-keys \
          "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    */
    nix.settings = lib.mkIf cfg.cuda {
      substituters = [ "https://cache.nixos-cuda.org" ];
      trusted-public-keys = [
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
    };
  };
}
