# nix build --no-link .#tests.proxy.switch-bare
# The proxy switch turned on in a fork that deleted one of the two proxies it routes through.
{
  host,
}:

let
  vless.my.apps.vlessProxy = {
    enable = true;
    outboundFile = "/etc/vless/outbound.json";
  };
  wg.my.apps.wgProxy = {
    enable = true;
    endpointFile = "/etc/wg/endpoint.json";
  };
  switch.my.apps.proxySwitch.switches.main = {
    port = 2082;
    controlPort = 2083;
  };
in
host.bare [
  {
    on = [
      "apps/proxy/proxy-switch.nix"
      "apps/proxy/wg-proxy.nix"
    ];
    gone = "apps/proxy/vless-proxy.nix";
    config.imports = [
      switch
      wg
    ];
  }
  {
    on = [
      "apps/proxy/proxy-switch.nix"
      "apps/proxy/vless-proxy.nix"
    ];
    gone = "apps/proxy/wg-proxy.nix";
    config.imports = [
      switch
      vless
    ];
  }
]
