{ config, lib, ... }:

{
  config = lib.mkIf config.nyx.desktop.enable {
    boot.loader = {
      systemd-boot.enable = lib.mkDefault true;
      systemd-boot.configurationLimit = lib.mkDefault 15;
      efi.canTouchEfiVariables = lib.mkDefault true;
      timeout = lib.mkDefault 5;
    };
  };
}
