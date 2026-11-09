{ config, lib, pkgs, ... }:

let
  proxy = config.my.apps.wgProxy;
  engine = config.confine.packages.marinara-engine;

  proxied = pkgs.writeShellScriptBin "marinara" ''
    set -euo pipefail

    service="sing-box-wg-proxy.service"
    proxy_host=${lib.escapeShellArg proxy.listen}
    proxy_port=${toString proxy.port}

    systemctl --user start "$service"

    ready=0
    for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 100); do
      if ${lib.getExe pkgs.netcat-openbsd} -z "$proxy_host" "$proxy_port" 2>/dev/null; then
        ready=1
        break
      fi
      sleep 0.1
    done

    if [ "$ready" != 1 ]; then
      systemctl --user status "$service" --no-pager || true
      exit 1
    fi

    export NODE_USE_ENV_PROXY=1
    export HTTP_PROXY="http://$proxy_host:$proxy_port"
    export HTTPS_PROXY="http://$proxy_host:$proxy_port"
    export NO_PROXY="127.0.0.1,localhost"

    ${lib.getExe engine} "$@" &
    app_pid=$!

    cleanup() {
      if [ -n "''${app_pid:-}" ]; then
        kill "$app_pid" 2>/dev/null || true
      fi
      systemctl --user stop "$service" || true
    }

    trap cleanup INT TERM EXIT
    wait "$app_pid"
    status=$?
    trap - INT TERM EXIT
    systemctl --user stop "$service" || true
    exit "$status"
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
      fromHost = [ 8000 ];
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
