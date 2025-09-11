# NOTE not imported
{
  lib,
  config,
  ...
}: {
  options.nyx.programs.gdm.enable = lib.mkEnableOption "gdm";
  config = lib.mkIf config.nyx.programs.gdm.enable {
    services.xserver.displayManager.gdm = {
      enable = true;
      wayland = true;
      settings = {
        greeter = {
          Include = builtins.concatStringsSep "," config.nyx.data.users;
        };
      };
    };
  };
}
