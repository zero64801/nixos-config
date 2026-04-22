{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.llama-cpp;
in
{
  options.nyx.apps.llama-cpp = {
    enable = lib.mkEnableOption "Llama-cpp app";

    rocm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable rocm support.";
      example = false;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      ((llama-cpp.overrideAttrs (final: prev: {
        version = "8729";
        patches = [];
        postPatch = "";
        src = pkgs.fetchFromGitHub {
          owner = "ggml-org";
          repo = "llama.cpp";
          tag = "b8729";
          hash = "sha256-PYdfg6+wOlkiT3G6MOkzEajH5+h7bvPB3RPKzmWQesI=";
          leaveDotGit = true;
          postFetch = ''
            git -C "$out" rev-parse --short HEAD > $out/COMMIT
            find "$out" -name .git -print0 | xargs -0 rm -rf
          '';
        };
        npmDepsHash = "sha256-eeftjKt0FuS0Dybez+Iz9VTVMA4/oQVh+3VoIqvhVMw=";
      })).override {
        rocmSupport = cfg.rocm;
      })
    ];

    networking.firewall.allowedTCPPorts = [
      3000
    ];
  };
}
