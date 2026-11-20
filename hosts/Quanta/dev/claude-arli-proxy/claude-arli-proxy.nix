{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.apps.claudeArliProxy;
  onDemand = import ../../../../apps/proxy/_on-demand.nix {
    inherit lib pkgs;
    systemd = config.systemd.package;
  };
  proxySwitch = config.my.apps.proxySwitch.switches.claude or null;
  proxySwitchUrl = "http://127.0.0.1:${toString proxySwitch.port}";

  raw = builtins.fromTOML (builtins.readFile ./_proxy/config.toml);
  inPromptDir =
    table:
    table
    // lib.mapAttrs (_: path: if lib.hasPrefix "/" path then path else "${cfg.promptDir}/${path}") (
      lib.filterAttrs (key: _: lib.hasPrefix "system_" key && lib.hasSuffix "_file" key) table
    );
  settings = raw // {
    defaults = inPromptDir (raw.defaults or { }) // {
      api_key_file = cfg.keyFile;
    };
    models = lib.mapAttrs (_: inPromptDir) (raw.models or { });
    listen_host = onDemand.backend;
    listen_port = cfg.port;
  };
  prefix = settings.model_prefix;

  models = [
    {
      name = "DeepSeek-V4.1-Flash-1017";
      description = "ArliAI · 552B · 512K context · images";
      compactWindow = 484000;
    }
    {
      name = "GLM-4.6-Derestricted-v5";
      description = "ArliAI · 355B · 198K context";
      compactWindow = 162000;
    }
    {
      name = "GLM-4.7";
      description = "ArliAI · 355B · 198K context";
      compactWindow = 162000;
    }
    {
      name = "MiMo-V2.6-Flash-MOPD";
      description = "ArliAI · 310B · 512K context";
      compactWindow = 484000;
    }
    {
      name = "Qwen3.8-Flash-Next";
      description = "ArliAI · 180B · 256K context · images";
      compactWindow = 222000;
    }
    {
      name = "Gemma-4-31B-it";
      description = "ArliAI · 31B · 256K context · images";
      compactWindow = 222000;
    }
    {
      name = "Qwen3.8-27B";
      description = "ArliAI · 27B · 256K context · images";
      compactWindow = 222000;
    }
  ];

  package = pkgs.stdenvNoCC.mkDerivation {
    pname = "claude-arli-proxy";
    version = "1";
    src = ./_proxy;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    nativeCheckInputs = [ pkgs.python3 ];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      python3 -B -m unittest test_arli_proxy
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      dir=$out/share/claude-arli-proxy
      mkdir -p "$dir"
      cp arli_proxy.py "$dir"/
      cp ${(pkgs.formats.toml { }).generate "config.toml" settings} "$dir/config.toml"
      makeWrapper ${lib.getExe pkgs.python3} $out/bin/claude-arli-proxy \
        --add-flags "-B $dir/arli_proxy.py --config $dir/config.toml"
      runHook postInstall
    '';
    meta.mainProgram = "claude-arli-proxy";
  };
in
{
  options.my.apps.claudeArliProxy = {
    enable = mkEnableOption ''
      a gateway on the loopback address that sends Claude Code's requests for ArliAI models to ArliAI and the rest to
      Anthropic. It starts on the first connection and stops when idle. Claude Code is pointed at it through the managed
      settings, and gets a placeholder login when it has no claude.ai login, so ArliAI models work without one
    '';

    port = mkOption {
      type = types.port;
      default = 8790;
      description = "Loopback port Claude Code connects to. Sandboxes running Claude Code need it forwarded to the host.";
    };

    idleTimeout = mkOption {
      type = types.str;
      default = "5min";
      description = "Time without a connection after which the gateway stops.";
    };

    keyFile = mkOption {
      type = types.str;
      description = "File holding the ArliAI API key, read on each request.";
    };

    promptDir = mkOption {
      type = types.str;
      description = ''
        Folder outside the repo that relative system prompt files in config.toml are read from. A prompt file is read
        again when it changes, so edits apply to the next request without a rebuild.
      '';
    };

    noLoginToken = mkOption {
      type = types.str;
      readOnly = true;
      default = "arli-proxy-no-login";
      description = "ANTHROPIC_AUTH_TOKEN a launcher sets when Claude Code has no claude.ai login, the proxy's NO_LOGIN_TOKEN.";
    };
  };

  config = mkIf cfg.enable {
    environment.etc."claude-code/managed-settings.d/claude-arli-proxy.json" = {
      mode = "0444";
      text = builtins.toJSON {
        env = {
          ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString cfg.port}";
          ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-5-5";
          CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING = "1";
          CLAUDE_CODE_MAX_CONTEXT_TOKENS = "524288";
          CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = toString settings.max_parallel;
        };
        modelPicker.options = map (m: {
          model = prefix + m.name;
          label = m.name;
          inherit (m) description;
        }) models;
        modelSettings = lib.listToAttrs (
          map (m: lib.nameValuePair (prefix + m.name) { autoCompactWindow = m.compactWindow; }) models
        );
      };
    };

    system.userActivationScripts.claude-arli-proxy = ''
      ${config.systemd.package}/bin/systemctl --user start --no-block claude-arli-proxy-relay.socket || true
    '';

    systemd.user = lib.mkMerge [
      (onDemand.front {
        name = "claude-arli-proxy-relay";
        core = "claude-arli-proxy.service";
        description = "Claude Code gateway to ArliAI";
        listen = "127.0.0.1";
        inherit (cfg) port idleTimeout;
      })
      {
        services.claude-arli-proxy = lib.mkMerge [
          (onDemand.core [ cfg.port ])
          {
            description = "Claude Code gateway to ArliAI";
            environment = lib.optionalAttrs (proxySwitch != null) {
              HTTPS_PROXY = proxySwitchUrl;
              HTTP_PROXY = proxySwitchUrl;
              NO_PROXY = "localhost,127.0.0.1,::1";
            };
            serviceConfig = {
              Type = "exec";
              ExecStart = lib.getExe package;
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
