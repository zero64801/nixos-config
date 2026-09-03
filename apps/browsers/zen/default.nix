{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.apps.zen;
  profilePath = ".config/zen/default";

  addons = if cfg.addonPins == null then { } else pkgs.util.importAddons cfg.addonPins;

  lock = x: {
    Value = x;
    Status = "locked";
  };

  # Hardening baseline. Taste and hardware belong to the host, these do not.
  basePolicies = {
    AutofillAddressEnabled = true;
    AutofillCreditCardEnabled = false;
    DisableAppUpdate = true;
    DisableFeedbackCommands = true;
    DisableFirefoxStudies = true;
    DisablePocket = true;
    DisableTelemetry = true;
    DontCheckDefaultBrowser = true;
    NoDefaultBookmarks = true;
    OfferToSaveLogins = false;
    EnableTrackingProtection = {
      Value = true;
      Locked = true;
      Cryptomining = true;
      Fingerprinting = true;
    };
    FirefoxHome = {
      Pocket = false;
      Snippets = false;
      SponsoredTopSites = false;
    };
    FirefoxSuggest = {
      SponsoredSuggestions = false;
      ImproveSuggest = false;
    };
    PasswordManagerEnabled = false;
    UserMessaging.SkipOnboarding = true;
  };

  basePreferences = {
    "browser.contentblocking.category" = lock "strict";
    "dom.private-attribution.submission.enabled" = lock false;
    "browser.ml.chat.enabled" = lock false;
    # Required for the userChrome option to take effect at all.
    "toolkit.legacyUserProfileCustomizations.stylesheets" = lock true;
  };

  mkExtensionPolicy = extensions: {
    "*" = {
      installation_mode = "blocked";
      blocked_install_message = "Install extensions through Nix.";
    };
  } // builtins.listToAttrs (
    builtins.map (e:
      let id = e.passthru.addonId;
      in {
        name = id;
        value = {
          install_url = "file://${e}/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${id}.xpi";
          installation_mode = "force_installed";
          private_browsing = true;
        };
      }
    ) extensions
  );
in
{
  options.my.apps.zen = {
    enable = lib.mkEnableOption "Zen Browser";

    addonPins = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = lib.literalExpression "./firefox-addons.json";
      description = ''
        A firefox-addons.json of AMO pins, imported with pkgs.util.importAddons
        and managed by `addon-pin`. Everything it lists is force installed and
        every other extension is blocked, including when this is null.
      '';
    };

    preferences = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = ''
        Firefox preferences merged over the hardening baseline. Values are
        given raw and locked by the module.
      '';
    };

    profileSettings = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = "Unlocked about:config settings for the default profile.";
    };

    search = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = "Passed through to the default profile's search block.";
    };

    userChrome = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "userChrome.css for the default profile.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
  {
    hm = {
      imports = [
        inputs.zen-browser.homeModules.beta
      ];

      programs.zen-browser = {
        enable = true;

        policies = basePolicies // {
          Preferences = basePreferences // lib.mapAttrs (_: lock) cfg.preferences;
          ExtensionSettings = mkExtensionPolicy (lib.attrValues addons);
        };

        profiles.default = {
          name = "Default";
          inherit (cfg) search userChrome;
          settings = cfg.profileSettings;
        };

        nativeMessagingHosts = [ ];
      };
    };

    # Updates the AMO pins that addonPins points at.
    environment.systemPackages = [ (pkgs.callPackage ./_addon-pin.nix { }) ];

    # Persist the whole profile: SQLite -wal files and rename-replaced json/txt break under per-file bind mounts.
    my.persistence.home.directories = [
      profilePath
    ];

  }
  (lib.mkIf (config.my.stylix.enable or false) {
    hm.stylix.targets.zen-browser.profileNames = [ "default" ];
  })
  ]);
}
