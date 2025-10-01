{
  lib,
  config,
  ...
}: {
  options.nyx.programs.firefox.enable = lib.mkEnableOption "firefox";
  config = lib.mkIf config.nyx.programs.firefox.enable {
    programs.firefox = {
      enable = true;
    };
  };
}
