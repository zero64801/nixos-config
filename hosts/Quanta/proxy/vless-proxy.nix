{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.vlessProxy;

  vlessLinkToOutbound = pkgs.writeShellScriptBin "quanta-vless-link-to-outbound" ''
    exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
import json
import re
import sys
from urllib.parse import parse_qs, unquote, urlsplit


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def truthy(value):
    return str(value).lower() in {"1", "true", "yes", "on"}


def main():
    if len(sys.argv) != 2:
        die("usage: quanta-vless-link-to-outbound 'vless://...'")

    link = sys.argv[1].strip()
    if not link.startswith("vless://"):
        die("expected a vless:// share link")

    parsed = urlsplit(link)
    query = parse_qs(parsed.query, keep_blank_values=True)

    def one(name, default=None):
        values = query.get(name)
        if not values:
            return default
        return unquote(values[-1])

    uuid = unquote(parsed.username or "")
    server = parsed.hostname
    port = parsed.port

    if not uuid:
        die("missing VLESS uuid/user")
    if not server:
        die("missing VLESS server")
    if not port:
        die("missing VLESS server port")

    outbound = {
        "type": "vless",
        "tag": "vless-out",
        "server": server,
        "server_port": port,
        "uuid": uuid,
    }

    flow = one("flow")
    if flow:
        outbound["flow"] = flow

    packet_encoding = one("packetEncoding") or one("packet_encoding")
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding

    security = (one("security") or "none").lower()
    if security in {"tls", "reality"}:
        tls = {"enabled": True}

        server_name = one("sni") or one("serverName") or server
        if server_name:
            tls["server_name"] = server_name

        alpn = one("alpn")
        if alpn:
            tls["alpn"] = [item for item in re.split(r"[, ]+", alpn) if item]

        fingerprint = one("fp") or one("fingerprint")
        if fingerprint:
            tls["utls"] = {
                "enabled": True,
                "fingerprint": fingerprint,
            }

        insecure = one("allowInsecure") or one("insecure")
        if insecure is not None:
            tls["insecure"] = truthy(insecure)

        if security == "reality":
            reality = {}
            public_key = one("pbk") or one("publicKey") or one("public_key")
            short_id = one("sid") or one("shortId") or one("short_id")
            if public_key:
                reality["public_key"] = public_key
            if short_id is not None:
                reality["short_id"] = short_id
            if reality:
                tls["reality"] = reality

        outbound["tls"] = tls
    elif security not in {"", "none"}:
        print(f"warning: unknown security={security!r}; leaving TLS disabled", file=sys.stderr)

    transport_type = one("type", "tcp").lower()
    if transport_type not in {"", "none", "tcp"}:
        transport = {"type": transport_type}

        path = one("path")
        host = one("host")

        if transport_type in {"ws", "httpupgrade"}:
            if path:
                transport["path"] = path
            if host:
                transport["headers"] = {"Host": host}
        elif transport_type == "grpc":
            service_name = one("serviceName") or one("service_name")
            if service_name:
                transport["service_name"] = service_name
        else:
            print(
                f"warning: transport type {transport_type!r} may need manual sing-box fields",
                file=sys.stderr,
            )

        outbound["transport"] = transport

    print(json.dumps(outbound, indent=2, sort_keys=False))


if __name__ == "__main__":
    main()
PY
  '';

  singBoxConfigScript = pkgs.writeShellScript "sing-box-vless-socks" ''
    set -euo pipefail

    runtime_dir="''${RUNTIME_DIRECTORY:-}"
    if [ -z "$runtime_dir" ]; then
      runtime_dir="''${XDG_RUNTIME_DIR:?}/sing-box-vless-socks"
      mkdir -p "$runtime_dir"
      chmod 700 "$runtime_dir"
    fi

    config_file="$runtime_dir/config.json"
    tmp_config="$config_file.tmp"

    ${lib.getExe pkgs.jq} \
      -n \
      --arg socksListen ${lib.escapeShellArg cfg.socks.listen} \
      --argjson socksPort ${toString cfg.socks.port} \
      --slurpfile outbound ${lib.escapeShellArg cfg.outboundFile} \
      '
        ($outbound[0] + { tag: ($outbound[0].tag // "vless-out") }) as $out |
        {
          log: {
            level: "info",
            timestamp: true
          },
          inbounds: [
            {
              type: "socks",
              tag: "socks-in",
              listen: $socksListen,
              listen_port: $socksPort
            }
          ],
          outbounds: [
            $out,
            {
              type: "direct",
              tag: "direct"
            }
          ],
          route: {
            rules: [
              {
                inbound: "socks-in",
                action: "sniff"
              }
            ],
            final: $out.tag
          }
        }
      ' > "$tmp_config"

    test -s "$tmp_config"
    ${lib.getExe pkgs.sing-box} check -c "$tmp_config"
    mv "$tmp_config" "$config_file"
    exec ${lib.getExe pkgs.sing-box} run -c "$config_file"
  '';
in
{
  options.nyx.apps.vlessProxy = {
    enable = lib.mkEnableOption "local sing-box SOCKS5 proxy backed by a VLESS outbound";

    outboundFile = lib.mkOption {
      type = lib.types.str;
      default = "/persist/local/secrets/sing-box/quanta-vless-outbound.json";
      description = ''
        Runtime JSON file containing a single sing-box VLESS outbound object.
        Keep this outside the Nix store because it contains server details.
      '';
    };

    socks = {
      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address for the local SOCKS5 proxy to listen on.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 1080;
      description = "Port for the local SOCKS5 proxy.";
      };
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start the proxy automatically at user login instead of on demand.";
    };

    discordWrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add a separate Discord launcher that uses the local SOCKS5 proxy.";
      };

      stopProxyOnExit = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Stop the user proxy service when the proxied Discord launcher exits.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        pkgs.sing-box
        vlessLinkToOutbound
      ];

      systemd.user.services.sing-box-vless-socks = {
        description = "Local SOCKS5 proxy to VLESS via sing-box";
        after = [ "network.target" ];

        unitConfig.ConditionPathExists = cfg.outboundFile;

        serviceConfig = {
          Type = "exec";
          RuntimeDirectory = "sing-box-vless-socks";
          RuntimeDirectoryMode = "0700";
          ExecStart = singBoxConfigScript;
          Restart = "on-failure";
          RestartSec = "3s";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      } // lib.optionalAttrs cfg.autoStart {
        wantedBy = [ "default.target" ];
      };
    }

    (lib.mkIf (cfg.discordWrapper.enable && config.nyx.apps.discord.enable) {
      hm.imports = [
        ({ config, lib, pkgs, ... }:
          let
            proxyUrl = "socks5://${cfg.socks.listen}:${toString cfg.socks.port}";
            nixcordDiscord = "${config.home.profileDirectory}/bin/Discord";
            stopProxy = lib.optionalString cfg.discordWrapper.stopProxyOnExit ''
              systemctl --user stop sing-box-vless-socks.service || true
            '';
            discordProxy = pkgs.writeShellScriptBin "discord-proxy" ''
              set -euo pipefail

              service="sing-box-vless-socks.service"
              proxy_host=${lib.escapeShellArg cfg.socks.listen}
              proxy_port=${toString cfg.socks.port}

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

              ${lib.escapeShellArg nixcordDiscord} --proxy-server=${lib.escapeShellArg proxyUrl} "$@" &
              discord_pid=$!

              cleanup() {
                if [ -n "''${discord_pid:-}" ]; then
                  kill "$discord_pid" 2>/dev/null || true
                fi
                ${stopProxy}
              }

              trap cleanup INT TERM EXIT
              wait "$discord_pid"
              status=$?
              trap - INT TERM EXIT
              ${stopProxy}
              exit "$status"
            '';
          in
          {
            home.packages = [
              discordProxy
            ];

            xdg.desktopEntries.discord-proxy = {
              name = "Discord (Proxy)";
              genericName = "Internet Messenger";
              comment = "Launch Discord through the local VLESS SOCKS5 proxy";
              exec = "${discordProxy}/bin/discord-proxy";
              icon = "discord";
              terminal = false;
              categories = [
                "Network"
                "InstantMessaging"
                "Chat"
              ];
            };
          })
      ];
    })
  ]);
}
