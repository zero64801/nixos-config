{ config, lib, pkgs, ... }:

let
  proxy = config.my.apps.wgProxy;
  tavern = config.confine.packages.sillytavern;
  port = 8000;

  proxyUrl = "http://${proxy.listen}:${toString proxy.port}";

  proxied = pkgs.writeShellScriptBin "sillytavern" ''
    export NODE_USE_ENV_PROXY=1
    export HTTP_PROXY=${lib.escapeShellArg proxyUrl}
    export HTTPS_PROXY=${lib.escapeShellArg proxyUrl}
    export NO_PROXY="127.0.0.1,localhost"

    exec ${tavern}/bin/sillytavern \
      --requestProxyEnabled \
      --requestProxyUrl ${lib.escapeShellArg proxyUrl} \
      --requestProxyBypass localhost 127.0.0.1 \
      "$@"
  '';

  direct = pkgs.writeShellScriptBin "sillytavern-direct" ''
    exec ${tavern}/bin/sillytavern --requestProxyEnabled=false "$@"
  '';
in
{
  confine.apps.sillytavern = {
    package = pkgs.sillytavern;
    appId = "app.sillytavern.SillyTavern";
    install = false;

    network = "isolated";
    networkPorts = {
      toHost = [ 3000 ] ++ lib.optional proxy.enable proxy.port;
      fromHost = [ "0.0.0.0/${toString port}" ];
    };

    envPassthrough = [
      "NODE_USE_ENV_PROXY"
      "HTTP_PROXY"
      "HTTPS_PROXY"
      "NO_PROXY"
    ];
  };

  environment.systemPackages = [ direct ] ++ lib.optional proxy.enable proxied;

  networking.firewall.allowedTCPPorts = [ port ];
}
