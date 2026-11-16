{ config, lib, pkgs, ... }:

let
  switches = config.my.apps.proxySwitch.switches;
  vless = config.my.apps.vlessProxy;
  wg = config.my.apps.wgProxy;
  onDemand = import ./_on-demand.nix {
    inherit lib pkgs;
    systemd = config.systemd.package;
  };

  # Reached through their sockets, so a proxy only runs while a route through it carries a connection.
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

  mkSwitch =
    name: sw:
    let
      unit = "proxy-switch-${name}";
      folder = "proxy-switch/${name}";
      api = "http://${sw.listen}:${toString sw.controlPort}";

      # The route is the Clash mode, the one thing the control API changes without a restart.
      baseConfig = pkgs.writeText "${unit}.json" (
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
              listen_port = sw.port;
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
              external_controller = "${onDemand.backend}:${toString sw.controlPort}";
              default_mode = sw.defaultRoute;
            };
            cache_file.enabled = true;
          };
        }
      );

      # Made once per login and before the switch first runs, since the route command reads it ahead of the request that starts the switch.
      ensureSecret = pkgs.writeShellScript "${unit}-secret" ''
        set -euo pipefail
        PATH=${lib.makeBinPath [ pkgs.coreutils ]}

        dir="''${XDG_RUNTIME_DIR:?}/${folder}"
        mkdir -p "$dir"
        chmod 700 "$dir"
        if [ ! -s "$dir/secret" ]; then
          tmp=$(mktemp "$dir/secret.XXXXXX")
          head -c 24 /dev/urandom | basenc --base64url > "$tmp"
          # A hard link fails where the name is taken, so two starts at once end up with one secret.
          ln "$tmp" "$dir/secret" 2>/dev/null || true
          rm "$tmp"
        fi
      '';

      configScript = pkgs.writeShellScript unit ''
        set -euo pipefail

        ${ensureSecret}

        runtime_dir="''${XDG_RUNTIME_DIR:?}/${folder}"
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
    in
    {
      command = pkgs.writeShellApplication {
        name = sw.command;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          routes=(${lib.escapeShellArgs routes})
          api=${lib.escapeShellArg api}
          secret_file="''${XDG_RUNTIME_DIR:?}/${folder}/secret"

          die() {
            echo "${sw.command}: $*" >&2
            exit 1
          }

          usage() {
            echo "usage: ${sw.command} [''${routes[*]}]" >&2
            echo "Without an argument, prints the route the ${name} proxy switch uses." >&2
            exit 2
          }

          [ "$#" -le 1 ] || usage
          case "''${1:-}" in -h | --help) usage ;; esac

          [ -r "$secret_file" ] || die "the ${name} proxy switch is not set up here ($secret_file is missing)"

          # The secret goes in on stdin so it never shows up in a process list.
          api_call() {
            local path=$1
            shift
            printf 'Authorization: Bearer %s\n' "$(cat "$secret_file")" \
              | curl --silent --show-error --fail --max-time 10 --header @- "$@" "$api$path" \
              || die "the ${name} proxy switch at $api did not take the request"
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

      units = lib.mkMerge [
        (onDemand.front {
          name = "${unit}-relay";
          core = "${unit}.service";
          description = "${name} proxy switch";
          inherit (sw) listen port idleTimeout;
        })
        (onDemand.front {
          name = "${unit}-control";
          core = "${unit}.service";
          description = "control API of the ${name} proxy switch";
          inherit (sw) listen idleTimeout;
          port = sw.controlPort;
          socketConfig.ExecStartPre = ensureSecret;
        })
        {
          services.${unit} = lib.mkMerge [
            (onDemand.core [
              sw.port
              sw.controlPort
            ])
            {
              description = "Local proxy for ${name} whose route switches live between direct and the local proxies";

              serviceConfig = {
                Type = "exec";
                StateDirectory = folder;
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

  built = lib.mapAttrsToList mkSwitch switches;
  ports = lib.concatMap (sw: [ sw.port sw.controlPort ]) (lib.attrValues switches) ++ map (u: u.port) upstreams;
in
{
  options.my.apps.proxySwitch.switches = lib.mkOption {
    default = { };
    description = ''
      Local HTTP proxies whose route switches live between a direct connection and the local VLESS and WireGuard
      proxies, each with its own route and its own command to pick it. One per app, or per group of apps that should
      move together. A switch starts on its first connection and stops once idle.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            listen = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Address the proxy and its control API listen on.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              description = "Port for the HTTP proxy that apps are pointed at.";
            };

            controlPort = lib.mkOption {
              type = lib.types.port;
              description = ''
                Port of the control API the route command talks to. It asks for the secret in
                $XDG_RUNTIME_DIR/proxy-switch/NAME/secret, a folder a sandbox needs bound in to switch routes.
              '';
            };

            command = lib.mkOption {
              type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
              default = "${name}-route";
              description = "Name of the command that prints or picks this switch's route.";
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
                Route used until another is picked with the route command. A picked route is kept across restarts.
                off connects directly, though never to the host's own loopback addresses.
              '';
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (switches != { }) {
    assertions = [
      {
        assertion = upstreams != [ ];
        message = "my.apps.proxySwitch needs my.apps.vlessProxy or my.apps.wgProxy enabled.";
      }
      {
        assertion = lib.allUnique ports;
        message = "my.apps.proxySwitch.switches use a port twice, among themselves or with the proxies behind them.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: sw: [
        {
          assertion = builtins.match "[a-z0-9][a-z0-9-]*" name != null;
          message = "my.apps.proxySwitch.switches.${name}: a name is lower case letters, digits and dashes.";
        }
        {
          assertion = lib.elem sw.defaultRoute routes;
          message = "my.apps.proxySwitch.switches.${name}.defaultRoute is ${sw.defaultRoute}, but that proxy is not enabled.";
        }
        (onDemand.listenAssertion "my.apps.proxySwitch.switches.${name}.listen" sw.listen)
      ]) switches
    );

    environment.systemPackages = map (s: s.command) built;

    my.persistence.home.directories = [ ".local/state/proxy-switch" ];

    systemd.user = lib.mkMerge (map (s: s.units) built);
  };
}
