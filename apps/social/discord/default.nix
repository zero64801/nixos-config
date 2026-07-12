{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.discord;
  sources = (pkgs.util.importFlake ./sources).inputs;
  remotePlugins = (pkgs.util.importFlake ./plugins).inputs;
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
          sources.nixcord.homeModules.nixcord
        ];

        programs.nixcord = {
          enable = true;
          discord = {
            # OpenAsar's moduleUpdater mkdirs inside the read-only store and hangs bootstrap before window creation (discord 1.0.137 pairing).
            openASAR.enable = false;
            autoscroll.enable = true;
            vencord.package = sources.nixcord.packages.${pkgs.stdenv.hostPlatform.system}.vencord.overrideAttrs (old: {
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
              ClearURLs.enable = true;
              fakeNitro = {
                enable = true;
                transformCompoundSentence = true;
              };
              fixImagesQuality.enable = true;
              fixYoutubeEmbeds.enable = true;
              # nixcord warns iLoveSpam -> IloveSpam, but this rev only defines
              # the old option name; rename here once the sub-flake updates.
              iLoveSpam.enable = true;
              loadingQuotes.enable = true;
              messageLinkEmbeds.enable = true;
              noBlockedMessages.enable = true;
              replaceGoogleSearch = {
                enable = true;
                customEngineName = "DuckDuckGo";
                customEngineURL = "https://duckduckgo.com/";
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
