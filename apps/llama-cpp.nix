{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.llama-cpp;

  # Pinned to llama.cpp b9551 — first mainline build with Gemma-4 MTP drafter
  # support (PR #23398, merged 2026-06-07). nixpkgs still ships b9309, so we
  # bump version + src hash + the web-ui npm-deps hash here. finalAttrs makes
  # npmDeps refetch automatically from the new src + npmDepsHash.
  #
  # NOTE: rocm is intentionally OFF. GGML_HIP recompiles the *same* ggml-cuda
  # backend sources with the ROCm/LLVM compiler, so it cannot coexist with
  # GGML_CUDA (nvcc) in one binary — CUDA + ROCm is not a valid combo. The
  # viable heterogeneous path is CUDA(3090) + Vulkan(9070XT), and Vulkan is
  # also the faster backend on RDNA4/gfx1201 today, so nothing is lost.
  llama-cpp-mtp = (pkgs.llama-cpp.override {
    vulkanSupport = cfg.vulkan;
    cudaSupport = cfg.cuda;
    rocmSupport = cfg.rocm;
    rpcSupport = cfg.rpc;
  }).overrideAttrs (old: {
    version = "9551";
    src = pkgs.fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      tag = "b9551";
      hash = "sha256-bxTimc9SoK2ceNkA6CpFjcgYc3hV4z+jM75x6a+jA3U=";
      leaveDotGit = true;
      postFetch = ''
        git -C "$out" rev-parse --short HEAD > $out/COMMIT
        find "$out" -name .git -print0 | xargs -0 rm -rf
      '';
    };
    npmDepsHash = "sha256-pjdbI6NcZRlJVd62xhgbLhWrwFYwgsIwjORqvo1+VD8=";
  });
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

    rpc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable RPC support.";
      example = false;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ llama-cpp-mtp ];

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
