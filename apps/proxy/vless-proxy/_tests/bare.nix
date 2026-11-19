# nix build --no-link .#tests.vless-proxy.bare
# The VLESS proxy turned on in a fork that deleted the app its launcher is for, or the sandbox that launcher tunnels from.
{
  host,
}:

let
  config.my.apps.vlessProxy = {
    enable = true;
    outboundFile = "/etc/vless/outbound.json";
  };
in
host.bare [
  {
    on = [ "apps/proxy/vless-proxy" ];
    gone = "apps/social/discord";
    inherit config;
  }
  {
    on = [ "apps/proxy/vless-proxy" ];
    gone = "apps/confine";
    inherit config;
  }
]
