{ config, lib, ... }:

{
  config = lib.mkIf config.nyx.desktop.enable {
    services.fwupd.enable = lib.mkDefault true;
    services.dbus.implementation = lib.mkDefault "broker";

    services.xserver.xkb = {
      layout = lib.mkDefault "us";
      variant = lib.mkDefault "";
    };

    hardware.enableAllFirmware = lib.mkDefault true;
    hardware.steam-hardware.enable = lib.mkDefault false;
  };
}
