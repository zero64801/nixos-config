{ config, lib, ... }:

{
  config = lib.mkIf config.nyx.desktop.enable {
    boot.loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = lib.mkDefault true;
      timeout = lib.mkDefault 5;
    };
  };
}
