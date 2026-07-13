{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.discord;
  sources = pkgs.util.importPins ./sources.json;
  remotePlugins = {
    inherit (sources) bigFileUpload;
  };
  localPlugins = {
    MyServerRoles = ./local-plugins/myServerRoles;
  };
  plugins = remotePlugins // localPlugins;
in
{
  options.nyx.apps.discord.enable = lib.mkEnableOption "Discord (Nixcord + Vencord)";

  config = lib.mkIf cfg.enable {
    nyx.persistence.home.directories = [
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
            commandLineArgs = [ "--enable-blink-features=MiddleClickAutoscroll" ];
            vencord.enable = true;
            vencord.package = inputs.nixcord.packages.${pkgs.stdenv.hostPlatform.system}.vencord.overrideAttrs (old: {
              src = sources.vencord // {
                inherit (old.src) owner repo;
              };
              postPatch = (old.postPatch or "") + lib.optionalString (plugins != {}) (''
                mkdir -p src/userplugins
              '' + lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: ''
                cp -r ${v} src/userplugins/${n}
              '') plugins));
            });
          };
          config = {
            frameless = true;
            plugins = {
              betterSettings.enable = true;
              betterUploadButton.enable = true;
              clearUrls.enable = true;
              fakeNitro = {
                enable = true;
                transformCompoundSentence = true;
              };
              fixImagesQuality.enable = true;
              fixYoutubeEmbeds.enable = true;
              iLoveSpam.enable = true;
              loadingQuotes.enable = true;
              messageLinkEmbeds.enable = true;
              noBlockedMessages.enable = true;
              replaceGoogleSearch = {
                enable = true;
                customEngineName = "DuckDuckGo";
                customEngineUrl = "https://duckduckgo.com/";
              };
              silentTyping = {
                enable = true;
                chatContextMenu = true;
                enabledGlobally = false;
                chatIcon = true;
              };
              translate.enable = true;
              typingIndicator.enable = true;
              unindent.enable = true;
              voiceMessages.enable = true;
              youtubeAdblock.enable = true;
              messageLogger.enable = true;
            };
          };
          extraConfig.plugins = {
            AccountPanelServerProfile.enabled = false;
            MyServerRoles.enabled = true;
            BigFileUpload = {
              enabled = true;
              fileUploader = "Catbox";
              autoSend = "No";
              autoFormat = "Yes";
              dragAndDropEnabled = "Yes";
              pasteEnabled = "Yes";
              respectNitroLimit = "Yes";
              nitroType = "full";
              disableFallbacks = "No";
              loggingLevel = "errors";
            };
          };
        };

        home.activation.extraDiscordSettings = let
          extraSettings = {
            OPEN_ON_STARTUP = false;
            MINIMIZE_TO_TRAY = false;
          };
        in config.lib.dag.entryAfter [ "writeBoundary" ] ''
          # Subshell keeps set -euo pipefail from leaking into later activation entries
          (
            set -euo pipefail
            mkdir -p "${config.programs.nixcord.discord.configDir}"
            config_dir="${config.programs.nixcord.discord.configDir}"
            if [ -f "$config_dir/settings.json" ]; then
              ${pkgs.jq}/bin/jq '. + ${builtins.toJSON extraSettings}' "$config_dir/settings.json" > "$config_dir/settings.json.tmp" && mv "$config_dir/settings.json.tmp" "$config_dir/settings.json"
            else
              echo '${builtins.toJSON extraSettings}' > "$config_dir/settings.json"
            fi
          )
        '';
      })
    ];
  };
}
