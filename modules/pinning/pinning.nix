{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) nullOr path str;

  cfg = config.nyx.pinning;

  pinsFilePath =
    if cfg.pinsFile != null then
      cfg.pinsFile
    else if cfg.flakePath != null then
      "${cfg.flakePath}/modules/pinning/pins.json"
    else
      null;

  nyx-pin = pkgs.callPackage ./_cli.nix {
    inherit (cfg) flakePath;
    inherit pinsFilePath;
  };

in
{
  options.nyx.pinning = {
    enable = mkEnableOption "flake input pinning management";

    flakePath = mkOption {
      type    = str;
      default = config.nyx.flakePath;
      description = "Path to the NixOS flake repository. Defaults to nyx.flakePath.";
    };

    pinsFile = mkOption {
      type    = nullOr str;
      default = null;
      description = ''
        Path to the pins.json file. Defaults to <flakePath>/modules/pinning/pins.json.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flakePath != null;
        message   = "nyx.pinning.flakePath must be set when nyx.pinning is enabled.";
      }
    ];

    environment.systemPackages = [ nyx-pin ];
  };
}
