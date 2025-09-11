{ lib, config, utils, ... }:

with lib;

let
  pathToMountUnit = path: (utils.escapeSystemdPath path) + ".mount";
    
  directoryWithOptions = types.submodule {
    options = {
      directory = mkOption { type = types.str; };
      user = mkOption { type = types.str; default = "root"; };
      group = mkOption { type = types.str; default = "root"; };
      mode = mkOption { type = types.str; default = "0755"; };
    };
  };

  persistenceOptions = { ... }: {
    options = {
      hideMounts = mkOption { type = types.bool; default = false; };
      directories = mkOption { type = types.listOf (types.either types.str directoryWithOptions); default = []; };
      files = mkOption { type = types.listOf types.str; default = []; };
      users = mkOption {
        type = types.attrsOf (types.submodule ({ ... }: {
          options = {
            directories = mkOption { type = types.listOf types.str; default = []; };
            files = mkOption { type = types.listOf types.str; default = []; };
          };
        }));
        default = {};
      };
      neededFor = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "A list of systemd services that depend on these persistent paths.";
        example = [ "jellyfin.service" ];
      };
    };
  };
in
{
  options.nyx.impermanence = {
    enable = mkEnableOption "impermanence support";
    mainPersistRoot = mkOption {
      type = types.str;
      description = "The primary persistence root path for this host.";
    };
    roots = mkOption {
      type = types.attrsOf (types.submodule persistenceOptions);
      default = {};
    };
  };

  config = mkIf config.nyx.impermanence.enable {
    assertions = [{
      assertion = config.nyx.impermanence.mainPersistRoot != null;
      message = "`nyx.impermanence.mainPersistRoot` must be set when `nyx.impermanence.enable` is true.";
    }];

    environment.persistence =
      mapAttrs (_: rootConfig: removeAttrs rootConfig [ "neededFor" ]) config.nyx.impermanence.roots;

    # This part remains the same. It correctly reads from the full `nyx.impermanence.roots`
    # configuration (including `neededFor`) to generate the systemd overrides.
    systemd.services =
      let
        generateOverridesForRoot = rootConfig:
          let
            directoryPaths = map (dir: if isString dir then dir else dir.directory) rootConfig.directories;
            mountUnits = map pathToMountUnit directoryPaths;
          in
          listToAttrs (map (serviceName:
            nameValuePair serviceName {
              after = mountUnits;
              requires = mountUnits;
            }
          ) rootConfig.neededFor);
      in
      mkMerge (attrValues (mapAttrs (_: generateOverridesForRoot) config.nyx.impermanence.roots));
  };
}
