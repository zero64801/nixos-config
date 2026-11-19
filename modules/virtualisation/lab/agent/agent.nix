{ config, lib, options, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  lab = config.my.virtualisation.lab;
  cfg = lab.agent;

  # Inside, the door takes the proxy's own port, the address a Claude Code with managed proxy settings already asks.
  port = toString (if cfg.proxy != null then cfg.proxy else 3128);
  hostGate = "${config.my.apps.hostGate.package}/bin/host-gate";
  tokenFile = lib.escapeShellArg cfg.tokenFile;

  guestMcp = pkgs.callPackage ./_guest-mcp.nix { } config.my.virtualisation.inspect.guestLibrary;

  run = pkgs.writeShellScript "vm-lab-agent-run" ''
    seat=''${1:?}
    shift
    export CLAUDE_CONFIG_DIR="$HOME/.claude-agent"
    CLAUDE_CODE_OAUTH_TOKEN=$(cat "$seat/token")
    export CLAUDE_CODE_OAUTH_TOKEN
    export HTTPS_PROXY=http://127.0.0.1:${port} HTTP_PROXY=http://127.0.0.1:${port} NO_PROXY=localhost,127.0.0.1,::1
    export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    if guest-agent ping 2>&1 | grep -q "without --control"; then
      echo "vm-lab: the session that is open was opened without --control, so the agent can read the guest's memory and screen and do nothing in it" >&2
      echo "vm-lab: for more, close that session and start vm-lab-agent by itself, or open it with vm-lab --control" >&2
      if [ -t 0 ]; then
        printf 'Press Enter to go on like this, Ctrl+C to stop: ' >&2
        read -r _
      fi
    fi
    ${hostGate} door 127.0.0.1:${port} "$seat/api.sock" &
    exec ${lib.getExe cfg.package} --strict-mcp-config --mcp-config "$seat/mcp.json" \
      --append-system-prompt "$(cat ${./_agent.md})" "$@"
  '';

  command = pkgs.writeShellScriptBin "vm-lab-agent" ''
    case "''${1:-}" in
      --token)
        token_file=${tokenFile}
        printf 'Paste the token that claude setup-token printed: ' >&2
        IFS= read -rs token
        echo >&2
        if [ -z "$token" ]; then
          echo "vm-lab-agent: nothing was pasted" >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname -- "$token_file")"
        (umask 077; printf '%s\n' "$token" > "$token_file")
        echo "vm-lab-agent: the agent's token is in $token_file"
        exit 0
        ;;
      -h | --help)
        echo "usage: vm-lab-agent [--join] DOMAIN [ARGUMENT...]"
        echo "       vm-lab-agent --token"
        echo "Claude Code inside vm-lab, with control of the guest DOMAIN. ARGUMENTs go to it."
        echo "It has a way out to its own service alone, a token of its own and the MCP servers of the folder's .mcp.json."
        echo "  --join   only enter a session that is open already, and open none"
        echo "  --token  store the token for the agent, which claude setup-token prints"
        exit 0
        ;;
    esac
    exec ${lab.package}/bin/vm-lab --agent "$@"
  '';
in
{
  options.my.virtualisation.lab.agent = {
    enable = mkEnableOption ''
      vm-lab-agent, which starts Claude Code inside the lab with control of the guest. It runs on a token of its own,
      reaches the hosts of its own service and nothing else, and gets the MCP servers that the folder's .mcp.json starts
      in the guest. What it is told about the lab is _agent.md next to this module, and it sees nothing of the Claude
      Code settings of the user who starts it. It needs the lab to have a sandbox
    '';

    package = lib.mkPackageOption pkgs "claude-code" { };

    tokenFile = mkOption {
      type = types.str;
      example = "/var/lib/secrets/lab-agent";
      description = ''
        File that holds the agent's token. claude setup-token prints one and vm-lab-agent --token stores it here.
        The user who starts the lab has to be able to write it, and nobody else should be able to read it.
      '';
    };

    proxy = mkOption {
      type = types.nullOr types.port;
      default = null;
      example = 8080;
      description = "Port of an HTTP proxy on this machine's loopback that the agent's way out goes through. null goes out directly.";
    };
  };

  config = lib.mkMerge [
    (mkIf lab.enable {
      my.virtualisation.lab.tools.guest-mcp = {
        package = guestMcp;
        summary = ''
          a program in the guest that speaks in lines of JSON, as an MCP server does, joined to this one's
          input and output: vm-lab --join DOMAIN guest-mcp --as-user PROGRAM... is such a server for this side
        '';
      };
    })

    (mkIf (lab.enable && cfg.enable) {
      assertions = [
        {
          assertion = lab.sandbox != null;
          message = "my.virtualisation.lab.agent keeps its agent away from the user's files and the network, which takes a sandbox, and my.virtualisation.lab.sandbox is null.";
        }
        {
          assertion = lib.hasAttrByPath [ "my" "apps" "hostGate" ] options;
          message = "my.virtualisation.lab.agent reaches its service through host-gate, and this system has no host-gate module.";
        }
      ];

      my.virtualisation.lab.modes.agent = {
        summary = ''
          start Claude Code inside the lab, with control of the guest, a way out to its own service alone,
          a token of its own and the MCP servers of the folder's .mcp.json. ARGUMENTs go to it.
          vm-lab-agent does the same, and vm-lab-agent --token stores that token
        '';

        kept.vm-lab-agent = ".claude-agent";

        start = ''
          control=1
          if [ ! -s ${tokenFile} ]; then
            echo "vm-lab: the agent has no token yet. Run claude setup-token, then vm-lab-agent --token to store what it prints" >&2
            exit 1
          fi
          for stale in "$sockets"/agent.*; do
            if [ -d "$stale" ] && ! kill -0 "''${stale##*/agent.}" 2>/dev/null; then
              ${pkgs.coreutils}/bin/rm -rf "''${stale:?}"
            fi
          done
          seat="$sockets/agent.$$"
          ${pkgs.coreutils}/bin/mkdir -m 700 "$seat"
          ${pkgs.coreutils}/bin/install -m 600 ${tokenFile} "$seat/token"
          if [ -f .mcp.json ]; then
            ${pkgs.jq}/bin/jq --arg domain "$domain" \
              '{mcpServers: ((.mcpServers // {}) | with_entries(select(.value.command == "vm-lab" and .value.args[0:2] == ["--join", $domain]) | .value |= (.command = .args[2] | .args = .args[3:])))}' \
              .mcp.json > "$seat/mcp.json"
          else
            echo '{"mcpServers":{}}' > "$seat/mcp.json"
          fi
          ${pkgs.bubblewrap}/bin/bwrap --unshare-all --share-net --die-with-parent --new-session --clearenv \
            --ro-bind /nix/store /nix/store --proc /proc --dev /dev --tmpfs /tmp \
            --ro-bind /etc/resolv.conf /etc/resolv.conf --bind "$seat" "$seat" \
            -- ${hostGate} gate "$seat/api.sock" api.anthropic.com:443 platform.claude.com:443 ${lib.optionalString (cfg.proxy != null) "--through 127.0.0.1:${port}"} \
            </dev/null 2>> "$seat/gate.log" &
          for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
            if [ -S "$seat/api.sock" ]; then break; fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "$seat/api.sock" ]; then
            echo "vm-lab: the gate to the API did not start" >&2
            exit 1
          fi
          set -- ${run} "$seat" "$@"
        '';
      };

      environment.systemPackages = [ command ];

      my.persistence.home.directories = [ ".local/state/vm-lab-agent" ];
    })
  ];
}
