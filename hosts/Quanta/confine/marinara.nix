{ config, lib, pkgs, ... }:

let
  proxy = config.my.apps.wgProxy;
  engine = config.confine.packages.marinara-engine;

  proxyUrl = "http://${proxy.listen}:${toString proxy.port}";

  proxied = pkgs.writeShellScriptBin "marinara" ''
    export NODE_USE_ENV_PROXY=1
    export HTTP_PROXY=${lib.escapeShellArg proxyUrl}
    export HTTPS_PROXY=${lib.escapeShellArg proxyUrl}
    export NO_PROXY="127.0.0.1,localhost"

    exec ${lib.getExe engine} "$@"
  '';

  direct = pkgs.writeShellScriptBin "marinara-direct" ''
    exec ${lib.getExe engine} "$@"
  '';
in
{
  confine.apps.marinara-engine = {
    package = pkgs.marinara-engine;
    appId = "dev.marinara.Engine";
    install = false;

    network = "isolated";
    networkPorts = {
      toHost = [ 3000 ] ++ lib.optional proxy.enable proxy.port;
      fromHost = [ "0.0.0.0/8000" ];
    };

    env.HOST = "0.0.0.0";
    env.PORT = "8000";

    env.ALLOW_UNAUTHENTICATED_PRIVATE_NETWORK = "true";
    env.CSRF_TRUSTED_ORIGINS = "http://quanta.local:8000,http://localhost:8000";

    envPassthrough = [
      "NODE_USE_ENV_PROXY"
      "HTTP_PROXY"
      "HTTPS_PROXY"
      "NO_PROXY"
    ];
  };

  environment.systemPackages = [ direct ] ++ lib.optional proxy.enable proxied;

  networking.firewall.allowedTCPPorts = [ 8000 ];
}
