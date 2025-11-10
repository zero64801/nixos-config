{ lib, ... }:

{
  # Common desktop services
  services.fstrim.enable = lib.mkDefault true;

  # Disable slow services
  systemd.services.NetworkManager-wait-online.enable = lib.mkDefault false;
}
