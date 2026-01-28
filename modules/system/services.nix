{ config, lib, ... }:

{
  config = lib.mkIf (!config.nyx.data.headless) {
    # System services
    services.fwupd.enable = lib.mkDefault true;
    services.dbus.implementation = lib.mkDefault "broker";

    # X11 keyboard configuration
    services.xserver.xkb = {
      layout = lib.mkDefault "us";
      variant = lib.mkDefault "";
    };

    # Firmware and hardware support
    hardware.enableAllFirmware = lib.mkDefault true;
    hardware.steam-hardware.enable = lib.mkDefault false;
  };
}
