{ config, lib, pkgs, ... }:

let
  cfg = config.my.apps.proxySwitch;
  vless = config.my.apps.vlessProxy;
  wg = config.my.apps.wgProxy;
  onDemand = import ./_on-demand.nix {
    inherit lib pkgs;
    systemd = config.systemd.package;
  };

  # Reached through their sockets, so a proxy only runs while its route carries a connection.
  upstreams =
    lib.optional vless.enable {
      name = "vless";
      server = vless.socks.listen;
      inherit (vless.socks) port;
    }
    ++ lib.optional wg.enable {
      name = "wg";
      server = wg.listen;
      inherit (wg) port;
    };

  routes = [ "off" ] ++ map (u: u.name) upstreams;
  api = "http://${cfg.listen}:${toString cfg.controlPort}";

  # The route is the Clash mode, the one thing the control API changes without a restart.
  baseConfig = pkgs.writeText "proxy-switch.json" (
    builtins.toJSON {
      log = {
        level = "info";
        timestamp = true;
      };
      dns.servers = [
        {
          type = "local";
          tag = "local";
        }
      ];
      inbounds = [
        {
          type = "http";
          tag = "proxy-in";
          listen = onDemand.backend;
          listen_port = cfg.port;
        }
      ];
      outbounds = [
        {
          type = "direct";
          tag = "off";
        }
      ]
      ++ map (u: {
        type = "socks";
        tag = u.name;
        inherit (u) server;
        server_port = u.port;
      }) upstreams;
      route = {
        rules = [
          # A direct connection leaves from the host, so without this a sandbox pointed here reaches the loopback services its own network keeps from it.
          # Names are resolved first, or one that points at loopback gets by.
          {
            clash_mode = "off";
            action = "resolve";
          }
          {
            clash_mode = "off";
            ip_cidr = [
              "127.0.0.0/8"
              "0.0.0.0/8"
              "::1/128"
              "::/128"
            ];
            action = "reject";
          }
          {
            clash_mode = "off";
            outbound = "off";
          }
        ]
        ++ map (u: {
          clash_mode = u.name;
          outbound = u.name;
        }) upstreams
        ++ [
          {
            network = [
              "tcp"
              "udp"
            ];
            action = "reject";
          }
        ];
        default_domain_resolver = "local";
      };
      experimental = {
        clash_api = {
          external_controller = "${onDemand.backend}:${toString cfg.controlPort}";
          default_mode = cfg.defaultRoute;
        };
        cache_file.enabled = true;
      };
    }
  );

  # Made once per login and before the switch first runs, since proxy-route reads it ahead of the request that starts the switch.
  ensureSecret = pkgs.writeShellScript "proxy-switch-secret" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    dir="''${XDG_RUNTIME_DIR:?}/proxy-switch"
    mkdir -p -m 700 "$dir"
    if [ ! -s "$dir/secret" ]; then
      tmp=$(mktemp "$dir/secret.XXXXXX")
      head -c 24 /dev/urandom | basenc --base64url > "$tmp"
      # A hard link fails where the name is taken, so two starts at once end up with one secret.
      ln "$tmp" "$dir/secret" 2>/dev/null || true
      rm "$tmp"
    fi
  '';

  configScript = pkgs.writeShellScript "proxy-switch" ''
    set -euo pipefail

    ${ensureSecret}

    runtime_dir="''${XDG_RUNTIME_DIR:?}/proxy-switch"
    state_dir="''${STATE_DIRECTORY:?}"
    config_file="$runtime_dir/config.json"
    tmp_config="$config_file.tmp"

    (umask 077 && ${lib.getExe pkgs.jq} \
      --rawfile secret "$runtime_dir/secret" \
      --arg cache "$state_dir/cache.db" \
      '.experimental.clash_api.secret = ($secret | rtrimstr("\n")) | .experimental.cache_file.path = $cache' \
      ${baseConfig} > "$tmp_config")

    test -s "$tmp_config"
    ${lib.getExe pkgs.sing-box} check -c "$tmp_config"
    mv "$tmp_config" "$config_file"
    exec ${lib.getExe pkgs.sing-box} run -c "$config_file"
  '';

  proxyRoute = pkgs.writeShellApplication {
    name = "proxy-route";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      routes=(${lib.escapeShellArgs routes})
      api=${lib.escapeShellArg api}
      secret_file="''${XDG_RUNTIME_DIR:?}/proxy-switch/secret"

      die() {
        echo "proxy-route: $*" >&2
        exit 1
      }

      usage() {
        echo "usage: proxy-route [''${routes[*]}]" >&2
        echo "Without an argument, prints the route in use." >&2
        exit 2
      }

      [ "$#" -le 1 ] || usage
      case "''${1:-}" in -h | --help) usage ;; esac

      [ -r "$secret_file" ] || die "the proxy switch is not set up here ($secret_file is missing)"

      # The secret goes in on stdin so it never shows up in a process list.
      api_call() {
        local path=$1
        shift
        printf 'Authorization: Bearer %s\n' "$(cat "$secret_file")" \
          | curl --silent --show-error --fail --max-time 10 --header @- "$@" "$api$path" \
          || die "the proxy switch at $api did not take the request"
      }

      if [ "$#" -eq 1 ]; then
        case " ''${routes[*]} " in
          *" $1 "*) ;;
          *) usage ;;
        esac
        api_call /configs --request PATCH --header 'Content-Type: application/json' \
          --data "$(jq -cn --arg mode "$1" '{ mode: $mode }')" >/dev/null
        # A connection opened on the old route would keep that route until it closes.
        api_call /connections --request DELETE >/dev/null
      fi

      now=$(api_call /configs | jq -r '.mode')
      [ "$#" -eq 0 ] || [ "$now" = "$1" ] || die "the route is still $now"
      echo "$now"
    '';
  };
in
{
  options.my.apps.proxySwitch = {
    enable = lib.mkEnableOption ''
      a local HTTP proxy whose route switches live between a direct connection and the local VLESS and
      WireGuard proxies, with the proxy-route command. It starts on its first connection and stops once idle
    '';

    listen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the proxy and its control API listen on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2082;
      description = "Port for the HTTP proxy that apps are pointed at.";
    };

    controlPort = lib.mkOption {
      type = lib.types.port;
      default = 2083;
      description = ''
        Port of the control API proxy-route talks to. It asks for the secret in
        $XDG_RUNTIME_DIR/proxy-switch/secret, which a sandbox needs bound in to switch routes.
      '';
    };

    idleTimeout = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "How long the switch keeps running after its last connection closes, as a systemd time span.";
    };

    defaultRoute = lib.mkOption {
      type = lib.types.enum [
        "off"
        "vless"
        "wg"
      ];
      default = "off";
      description = ''
        Route used until another is picked with proxy-route. A picked route is kept across restarts.
        off connects directly, though never to the host's own loopback addresses.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = upstreams != [ ];
        message = "my.apps.proxySwitch needs my.apps.vlessProxy or my.apps.wgProxy enabled.";
      }
      {
        assertion = lib.elem cfg.defaultRoute routes;
        message = "my.apps.proxySwitch.defaultRoute is ${cfg.defaultRoute}, but that proxy is not enabled.";
      }
      (onDemand.listenAssertion "my.apps.proxySwitch.listen" cfg.listen)
    ];

    environment.systemPackages = [ proxyRoute ];

    my.persistence.home.directories = [ ".local/state/proxy-switch" ];

    systemd.user = lib.mkMerge [
      (onDemand.front {
        name = "proxy-switch-relay";
        core = "proxy-switch.service";
        description = "proxy switch";
        inherit (cfg) listen port idleTimeout;
      })
      (onDemand.front {
        name = "proxy-switch-control";
        core = "proxy-switch.service";
        description = "control API of the proxy switch";
        inherit (cfg) listen idleTimeout;
        port = cfg.controlPort;
        socketConfig.ExecStartPre = ensureSecret;
      })
      {
        services.proxy-switch = lib.mkMerge [
          (onDemand.core [
            cfg.port
            cfg.controlPort
          ])
          {
            description = "Local proxy whose route switches live between direct and the local proxies";

            serviceConfig = {
              Type = "exec";
              StateDirectory = "proxy-switch";
              StateDirectoryMode = "0700";
              ExecStart = configScript;
              Restart = "on-failure";
              RestartSec = "3s";
              NoNewPrivileges = true;
              PrivateTmp = true;
            };
          }
        ];
      }
    ];
  };
}
