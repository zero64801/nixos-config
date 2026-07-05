{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.cli;

  nyx-cli = pkgs.callPackage ./_cli.nix {
    inherit (config.nyx) flakePath;
    hostName = config.networking.hostName;
  };

  completions = pkgs.writeTextDir "share/fish/vendor_completions.d/nyx.fish" (
    builtins.readFile ./_completions.fish
  );
in
{
  options.nyx.cli.enable = lib.mkEnableOption "nyx umbrella CLI";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      nyx-cli
      completions
    ];
  };
}
