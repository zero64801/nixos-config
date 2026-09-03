{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.apps.discord;
  sources = pkgs.util.importPins ./sources.json;
in
{
  options.my.apps.discord = {
    enable = lib.mkEnableOption "Discord (Nixcord + Vencord)";

    commandLineArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Extra Chromium flags passed to the Discord binary.";
    };

    localPlugins = lib.mkOption {
      type = with lib.types; attrsOf path;
      default = { };
      example = lib.literalExpression "{ MyPlugin = ./local-plugins/myPlugin; }";
      description = ''
        Vencord userplugins compiled into the build, plugin name to source
        directory. Enable each one through `extraConfig.plugins`.
      '';
    };

    vencordConfig = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = ''
        Passed through to `programs.nixcord.config`: frameless, themes and
        the plugins block.
      '';
    };

    extraConfig = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = ''
        Passed through to `programs.nixcord.extraConfig`, for plugins nixcord
        has no options for, userplugins included.
      '';
    };

    settings = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      example = { MINIMIZE_TO_TRAY = false; };
      description = "Keys merged into Discord's own settings.json on activation.";
    };
  };

  config = lib.mkIf cfg.enable {
    my.persistence.home.directories = [
      ".config/discord"
    ];

    hm.imports = [
      ({ config, pkgs, ... }: {
        imports = [
          inputs.nixcord.homeModules.nixcord
        ];

        programs.nixcord = {
          enable = true;
          discord = {
            # OpenAsar's moduleUpdater mkdirs inside the read-only store and hangs bootstrap before window creation (discord 1.0.137 pairing).
            openASAR.enable = false;
            inherit (cfg) commandLineArgs;
            vencord.enable = true;
            vencord.package = inputs.nixcord.packages.${pkgs.stdenv.hostPlatform.system}.vencord.overrideAttrs (old: {
              src = sources.vencord // {
                inherit (old.src) owner repo;
              };
              postPatch = (old.postPatch or "") + lib.optionalString (cfg.localPlugins != {}) (''
                mkdir -p src/userplugins
              '' + lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: ''
                cp -r ${v} src/userplugins/${n}
              '') cfg.localPlugins));
            });
          };
          config = cfg.vencordConfig;
          extraConfig = cfg.extraConfig;
        };

        home.activation = lib.mkIf (cfg.settings != { }) {
          extraDiscordSettings = config.lib.dag.entryAfter [ "writeBoundary" ] ''
            # Subshell keeps set -euo pipefail from leaking into later activation entries
            (
              set -euo pipefail
              mkdir -p "${config.programs.nixcord.discord.configDir}"
              config_dir="${config.programs.nixcord.discord.configDir}"
              if [ -f "$config_dir/settings.json" ]; then
                ${pkgs.jq}/bin/jq '. + ${builtins.toJSON cfg.settings}' "$config_dir/settings.json" > "$config_dir/settings.json.tmp" && mv "$config_dir/settings.json.tmp" "$config_dir/settings.json"
              else
                echo '${builtins.toJSON cfg.settings}' > "$config_dir/settings.json"
              fi
            )
          '';
        };
      })
    ];
  };
}
