{ config, lib, ... }:

{
  config = lib.mkIf config.nyx.desktop.enable {
    services.fwupd.enable = lib.mkDefault true;
    services.dbus.implementation = lib.mkDefault "broker";

    services.xserver.xkb = {
      layout = lib.mkDefault "us";
      variant = lib.mkDefault "";
    };

    hardware.enableRedistributableFirmware = lib.mkDefault true;
    hardware.steam-hardware.enable = lib.mkDefault false;

    environment.sessionVariables.NIXOS_OZONE_WL = "1";
  };
}
