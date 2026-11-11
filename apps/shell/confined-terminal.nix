{ config, lib, pkgs, ... }:

let
  cfg = config.my.apps.confinedTerminal;
in
{
  options.my.apps.confinedTerminal = {
    enable = lib.mkEnableOption ''
      the confined terminal: a "confined" command that opens a throwaway confine sandbox
      seeing only the folder it starts in, or runs one command in it, and a "Terminal (Confined)"
      entry that opens it in the default terminal
    '';

    scratchDir = lib.mkOption {
      type = lib.types.str;
      default = "Sandbox";
      description = "Folder under the home that gets a new scratch folder whenever the confined terminal starts in the home itself.";
    };

    tint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "#2a1418";
      description = "Background color while inside, for terminals that report their own. null leaves colors alone.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.callPackage ./_confined-terminal.nix { inherit (config.confine.lib) wrap; } { inherit (cfg) scratchDir tint; })
    ];

    my.persistence.home.directories = [
      cfg.scratchDir
      ".local/state/confined-terminal"
    ];
  };
}
