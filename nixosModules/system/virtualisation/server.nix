{
  config,
  lib,
  ...
}:

with lib;
  
{
  options.nyx.virtualisation.server.enable = mkEnableOption "Enable server virtualization networking features.";

  config = mkIf config.nyx.virtualisation.server.enable {
    assertions = [{
      assertion = config.nyx.virtualisation.base.enable;
      message = "nyx.virtualisation.server requires nyx.virtualisation.base to be enabled.";
    }];
  };
}
