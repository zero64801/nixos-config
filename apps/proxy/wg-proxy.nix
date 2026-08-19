{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.wgProxy;

  # Assembled at runtime because the endpoint file holds the private key and must never enter the store.
  configScript = pkgs.writeShellScript "sing-box-wg-proxy" ''
    set -euo pipefail

    runtime_dir="''${RUNTIME_DIRECTORY:-}"
    if [ -z "$runtime_dir" ]; then
      runtime_dir="''${XDG_RUNTIME_DIR:?}/sing-box-wg-proxy"
      mkdir -p "$runtime_dir"
      chmod 700 "$runtime_dir"
    fi

    config_file="$runtime_dir/config.json"
    tmp_config="$config_file.tmp"

    ${lib.getExe pkgs.jq} \
      -n \
      --arg listen ${lib.escapeShellArg cfg.listen} \
      --argjson port ${toString cfg.port} \
      --arg dns ${lib.escapeShellArg cfg.tunnelDns} \
      --slurpfile endpoint ${lib.escapeShellArg cfg.endpointFile} \
      '
        ($endpoint[0] + { tag: ($endpoint[0].tag // "wg-out") }) as $ep |
        {
          log: { level: "info", timestamp: true },
          dns: {
            servers: [ { tag: "tunnel-dns", type: "udp", server: $dns, detour: $ep.tag } ]
          },
          inbounds: [
            { type: "mixed", tag: "proxy-in", listen: $listen, listen_port: $port }
          ],
          endpoints: [ $ep ],
          outbounds: [ { type: "direct", tag: "direct" } ],
          route: {
            rules: [ { inbound: "proxy-in", action: "sniff" } ],
            final: $ep.tag,
            default_domain_resolver: "tunnel-dns"
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
  options.nyx.apps.wgProxy = {
    enable = lib.mkEnableOption "local HTTP/SOCKS proxy through a userspace WireGuard tunnel";

    endpointFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Runtime JSON file containing a single sing-box WireGuard endpoint
        object. Kept outside the store, it contains the private key.
      '';
    };

    listen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the local proxy to listen on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2081;
      description = "Port for the local HTTP and SOCKS proxy.";
    };

    tunnelDns = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "Resolver queried through the tunnel, so lookups do not leak.";
    };
  };

  config = lib.mkIf cfg.enable {
    # No wantedBy: consumers start it for exactly as long as they run.
    systemd.user.services.sing-box-wg-proxy = {
      description = "Local proxy through a userspace WireGuard tunnel";

      unitConfig.ConditionPathExists = cfg.endpointFile;

      serviceConfig = {
        Type = "exec";
        RuntimeDirectory = "sing-box-wg-proxy";
        RuntimeDirectoryMode = "0700";
        ExecStart = configScript;
        Restart = "on-failure";
        RestartSec = "3s";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
