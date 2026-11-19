{ config, lib, options, pkgs, ... }:

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
    assertions = [
      {
        assertion = options ? confine;
        message = "my.apps.confinedTerminal opens a confine sandbox, and this system has no confine module.";
      }
    ];

    # Left out without confine, so that the assertion above is what a rebuild ends with.
    environment.systemPackages = lib.optionals (options ? confine) [
      (pkgs.callPackage ./_confined-terminal.nix { inherit (config.confine.lib) wrap; } { inherit (cfg) scratchDir tint; })
    ];

    my.persistence.home.directories = [
      cfg.scratchDir
      ".local/state/confined-terminal"
    ];
  };
}
