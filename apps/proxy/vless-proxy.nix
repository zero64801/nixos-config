{ config, lib, pkgs, ... }:

let
  cfg = config.my.apps.vlessProxy;

  vlessLinkToOutbound = pkgs.writeShellScriptBin "vless-link-to-outbound" ''
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
        die("usage: vless-link-to-outbound 'vless://...'")

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

  tunMark = 1;
  tunTable = 100;
  ip = lib.getExe' pkgs.iproute2 "ip";
  strictFilter = config.confine.lib.seccomp { };

  tunSetup = pkgs.writeShellScript "sing-box-vless-tun" ''
    set -euo pipefail
    umask 077

    config="''${CONFINE_INSTANCE:?}/sing-box-tun.json"

    # pasta copies the host's LAN and global v6 addresses in, so they are replaced to keep the app from reading and reporting them.
    # This runs before sing-box starts because an address change under it stalls the connections it has open.
    uplink=$(${ip} -j -4 route show default | ${lib.getExe pkgs.jq} -r '.[0].dev // empty')
    if [ -z "$uplink" ]; then
      echo "sing-box-vless-tun: the namespace has no v4 default route" >&2
      exit 1
    fi
    ${ip} -4 addr flush dev "$uplink"
    ${ip} addr add 10.0.2.15/24 dev "$uplink"
    ${ip} route add default via 10.0.2.2 dev "$uplink"
    if [ -d /proc/sys/net/ipv6 ]; then
      ${ip} -6 addr flush dev "$uplink" scope global
    fi

    # The built in Mozilla roots keep the host's certificate store out of the sandbox below.
    ${lib.getExe pkgs.jq} \
      -n \
      --arg dns ${lib.escapeShellArg cfg.tunnelDns} \
      --argjson mark ${toString tunMark} \
      --slurpfile outbound ${lib.escapeShellArg cfg.outboundFile} \
      '
        ($outbound[0] + { tag: ($outbound[0].tag // "vless-out") }) as $out |
        {
          log: { level: "warn", timestamp: true },
          certificate: { store: "mozilla" },
          dns: {
            servers: [
              { type: "tcp", tag: "tunnel-dns", server: $dns, detour: $out.tag },
              { type: "local", tag: "local" }
            ],
            final: "tunnel-dns",
            strategy: "ipv4_only"
          },
          inbounds: [
            {
              type: "tun",
              tag: "tun-in",
              interface_name: "tun0",
              address: [ "172.19.0.1/30" ],
              stack: "mixed",
              auto_route: false
            }
          ],
          outbounds: [ $out ],
          route: {
            rules: [
              { action: "sniff" },
              { protocol: "dns", action: "hijack-dns" }
            ],
            final: $out.tag,
            default_mark: $mark,
            default_domain_resolver: "local"
          }
        }
      ' > "$config"

    ${lib.getExe pkgs.sing-box} check -c "$config"

    # sing-box keeps pasta's user and network namespaces because the tun and the routing mark need CAP_NET_ADMIN over them.
    # Left running, it dies with the app's sandbox, which is PID 1 of this namespace.
    exec {filter_fd}<${strictFilter}
    ${lib.getExe pkgs.bubblewrap} \
      --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup-try \
      --new-session --clearenv \
      --cap-drop ALL --cap-add CAP_NET_ADMIN \
      --seccomp "$filter_fd" \
      --ro-bind /nix/store /nix/store \
      --proc /proc \
      --dev /dev \
      --dev-bind /dev/net/tun /dev/net/tun \
      --tmpfs /tmp \
      --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
      --ro-bind "$config" /run/sing-box.json \
      -- ${lib.getExe pkgs.sing-box} run -c /run/sing-box.json </dev/null &
    sing_box=$!
    exec {filter_fd}<&-

    up=0
    for _ in $(${lib.getExe' pkgs.coreutils "seq"} 100); do
      if [[ $(${ip} -o link show tun0 2>/dev/null) == *,UP* ]]; then
        up=1
        break
      fi
      kill -0 "$sing_box" 2>/dev/null || break
      ${lib.getExe' pkgs.coreutils "sleep"} 0.05
    done
    if [ "$up" != 1 ]; then
      echo "sing-box-vless-tun: the tun never came up" >&2
      exit 1
    fi

    # The unreachable fallback outlives the tun, so a crash cuts the app off instead of letting it out directly.
    ${ip} route add default dev tun0 table ${toString tunTable}
    ${ip} route add unreachable default metric 4294967295 table ${toString tunTable}
    ${ip} rule add fwmark ${toString tunMark} lookup main priority 100
    ${ip} rule add lookup ${toString tunTable} priority 200

    if [ -d /proc/sys/net/ipv6 ]; then
      ${ip} -6 route add unreachable default table ${toString tunTable}
      ${ip} -6 rule add fwmark ${toString tunMark} lookup main priority 100
      ${ip} -6 rule add lookup ${toString tunTable} priority 200
    fi
  '';
in
{
  options.my.apps.vlessProxy = {
    enable = lib.mkEnableOption "local sing-box SOCKS5 proxy backed by a VLESS outbound";

    outboundFile = lib.mkOption {
      type = lib.types.str;
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

    tunnelDns = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "Resolver the tunnelled launcher queries over the VLESS outbound, so lookups do not leak.";
    };

    discordWrapper.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add a separate Discord launcher whose whole namespace, voice and
        screenshare UDP included, is tunnelled through the VLESS outbound.
      '';
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

    (lib.mkIf (cfg.discordWrapper.enable && config.my.apps.discord.enable) {
      # The voice engine sends its own UDP and ignores Chromium's proxy switch, so only a tun catches it.
      confine.apps.discord.networkSetups.vless = tunSetup;

      hm.imports = [
        ({ config, lib, pkgs, ... }:
          let
            nixcordDiscord = "${config.home.profileDirectory}/bin/Discord";
            discordProxy = pkgs.writeShellScriptBin "discord-proxy" ''
              export CONFINE_NETWORK_SETUP=vless
              exec ${lib.escapeShellArg nixcordDiscord} "$@"
            '';
          in
          {
            home.packages = [
              discordProxy
            ];

            xdg.desktopEntries.discord-proxy = {
              name = "Discord (Proxy)";
              genericName = "Internet Messenger";
              comment = "Launch Discord with all of its traffic tunnelled through VLESS";
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
