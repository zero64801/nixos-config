{
  lib,
  config,
  ...
}:
{
  options.nyx.impermanence = {
    enable = lib.mkEnableOption "impermanence support";

    persistence = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Configuration for environment.persistence from the impermanence module.";
      example = lib.literalExpression ''
        {
          "/persist/local".users.dx.directories = [ ".config/htop" ];
        }
      '';
    };
  };

  config = lib.mkIf config.nyx.impermanence.enable {
    environment.persistence = config.nyx.impermanence.persistence;
  };
}
