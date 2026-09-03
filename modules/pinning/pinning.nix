{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) nullOr str;

  cfg = config.my.pinning;

  pin = pkgs.callPackage ./_cli.nix {
    inherit (cfg) flakePath;
    pinsFilePath = cfg.pinsFile;
    hostName = config.networking.hostName;
  };

in
{
  options.my.pinning = {
    enable = mkEnableOption "flake input pinning management";

    flakePath = mkOption {
      type    = str;
      default = config.my.flakePath;
      description = "Path to the NixOS flake repository. Defaults to my.flakePath.";
    };

    pinsFile = mkOption {
      type    = nullOr str;
      default = null;
      description = ''
        Path to the pins.json file. Defaults to <flakePath>/hosts/<hostName>/pins.json,
        committed per host alongside persist.json.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pin
      (pkgs.writeTextDir "share/fish/vendor_completions.d/pin.fish" (builtins.readFile ./_completions.fish))
    ];
  };
}
