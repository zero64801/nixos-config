{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (!config.nyx.data.headless) {
    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;
      #supportedFilesystems = ["ntfs"];

      loader.timeout = 5;
    };
  };
}
