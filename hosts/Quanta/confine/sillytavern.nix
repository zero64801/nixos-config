{ config, lib, pkgs, ... }:

let
  proxy = config.my.apps.wgProxy;
  tavern = config.my.confine.packages.sillytavern;
  port = 8000;

  # Tunnel up for exactly as long as the server runs.
  proxied = pkgs.writeShellScriptBin "sillytavern" ''
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

    # The few native fetch users in the server ride the tunnel too, node-fetch goes through the request proxy below.
    export NODE_USE_ENV_PROXY=1
    export HTTP_PROXY="http://$proxy_host:$proxy_port"
    export HTTPS_PROXY="http://$proxy_host:$proxy_port"
    export NO_PROXY="127.0.0.1,localhost"

    # SillyTavern's own outbound proxy (proxy-agent on the http/https global agents), overriding the config's requestProxy. The model server stays loopback.
    ${tavern}/bin/sillytavern \
      --requestProxyEnabled \
      --requestProxyUrl "http://$proxy_host:$proxy_port" \
      --requestProxyBypass localhost 127.0.0.1 \
      "$@" &
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

  direct = pkgs.writeShellScriptBin "sillytavern-direct" ''
    exec ${tavern}/bin/sillytavern --requestProxyEnabled=false "$@"
  '';
in
{
  my.confine.apps.sillytavern = {
    package = pkgs.sillytavern;
    appId = "app.sillytavern.SillyTavern";
    # The launchers below are the entry points.
    install = false;

    /*
    Isolated with two fixed forwards: the model server on host loopback stays
    reachable, and the server port is bound on the host so LAN devices can
    reach it. The proxy port joins them when the tunnel launcher is in use.
    The config, data and whitelist live in the private home
    (~/.local/share/SillyTavern), migrated from the old netns setup. The
    config keeps listen on, port 8000, browser launch off and the LAN
    whitelist, so the launchers only toggle the request proxy.
    */
    network = "isolated";
    networkPorts = {
      toHost = [ 3000 ] ++ lib.optional proxy.enable proxy.port;
      # IPv4 only: a forward on host IPv6 reaches the server as the host's changing global address, which the whitelist
      # rejects and browsers then show as an empty reply. Refused on IPv6, localhost falls back to 127.0.0.1.
      fromHost = [ "0.0.0.0/${toString port}" ];
    };

    # The proxied launcher decides per run whether the sandbox sees a tunnel.
    envPassthrough = [
      "NODE_USE_ENV_PROXY"
      "HTTP_PROXY"
      "HTTPS_PROXY"
      "NO_PROXY"
    ];
  };

  environment.systemPackages = [ direct ] ++ lib.optional proxy.enable proxied;

  # The server port, reachable from the LAN while the sandbox runs.
  networking.firewall.allowedTCPPorts = [ port ];
}
