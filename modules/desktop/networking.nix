{ lib, config, ... }:

{
  config = lib.mkIf config.nyx.desktop.enable {
    networking = {
      nftables.enable = true;

      networkmanager = {
        enable = true;
        wifi = {
          powersave = false;
          macAddress = "stable";
        };
      };

      firewall.enable = true;
    };
  };
}
