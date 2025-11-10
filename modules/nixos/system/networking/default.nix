{ lib, config, ... }:

{
  config = lib.mkIf (!config.nyx.data.headless) {
    networking = {
      nftables.enable = true;

      networkmanager = {
        enable = true;
        wifi = {
          powersave = false;
          macAddress = "random";
        };
      };

      firewall = {
        enable = true;
        allowedTCPPortRanges = [ ];
        allowedUDPPortRanges = [ ];
      };
    };
  };
}
