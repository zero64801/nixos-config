{ ... }:

{
  networking.firewall = {
    allowedTCPPorts = [ 8080 5001 ];
    allowedUDPPorts = [ 5353 ];
  };
}
