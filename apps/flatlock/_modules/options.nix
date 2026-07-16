{
  lib,
  installation,
  hostname,
}:

let
  inherit (lib) mkEnableOption mkOption types;

  remoteType = types.either types.str (
    types.submodule {
      options = {
        location = mkOption {
          type = types.str;
          description = "URL of the flatpakrepo file or repository.";
        };
        gpgImport = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "GPG key imported when the remote is added.";
        };
        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "--no-gpg-verify" ];
          description = "Additional arguments passed to flatpak remote-add.";
        };
      };
    }
  );

  sourceType = types.either types.path types.str;
  packageType = types.either types.str (
    types.submodule {
      options = {
        appId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Flatpak application ID. It may be derived from a readable flatpakref.";
        };
        origin = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Remote to install from.";
        };
        branch = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "24.08";
          description = "Application branch.";
        };
        arch = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "x86_64";
          description = "Application architecture. An explicit architecture requires a branch.";
        };
        pin = mkOption {
          type = types.bool;
          default = true;
          description = "Hold the application at the commit recorded in the lock file.";
        };
        commit = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Explicit commit that takes precedence over the lock file.";
        };
        bundle = mkOption {
          type = types.nullOr sourceType;
          default = null;
          description = "Local bundle or fixed output bundle URL.";
        };
        flatpakref = mkOption {
          type = types.nullOr sourceType;
          default = null;
          description = "Local flatpakref or fixed output flatpakref URL.";
        };
        sha256 = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Hash required when bundle or flatpakref is an HTTP URL.";
        };
      };
    }
  );

  runtimeType = types.either types.str (
    types.submodule {
      options = {
        id = mkOption {
          type = types.str;
          description = "Flatpak runtime or extension ID.";
        };
        origin = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Remote to install from.";
        };
        branch = mkOption {
          type = types.str;
          description = "Runtime branch.";
        };
        arch = mkOption {
          type = types.str;
          description = "Runtime architecture.";
        };
        pin = mkOption {
          type = types.bool;
          default = true;
          description = "Hold the runtime at the commit recorded in the lock file.";
        };
        commit = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Explicit commit that takes precedence over the lock file.";
        };
      };
    }
  );

  overrideSectionsType = types.attrsOf (
    types.attrsOf (types.either types.str (types.listOf types.str))
  );
  overrideValueType = types.either types.path overrideSectionsType;
  legacyOverridesType = types.attrsOf overrideValueType;
  overridesSubmoduleType = types.submodule {
    options = {
      settings = mkOption {
        type = legacyOverridesType;
        default = { };
        description = "Application override settings or paths to override files.";
      };
      files = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = "Override files whose basenames are application IDs.";
      };
      writeMode = mkOption {
        type = types.enum [
          "merge"
          "replace"
        ];
        default = "replace";
        description = "Merge with unmanaged keys or replace each managed override file.";
      };
      pruneRemoved = mkOption {
        type = types.bool;
        default = false;
        description = "Delete override files that were previously managed and are no longer declared.";
      };
      pruneAll = mkOption {
        type = types.bool;
        default = false;
        description = "Delete every override file not present in the declaration.";
      };
    };
  };
in
{
  enable = mkEnableOption "declarative ${installation} Flatpak management";

  remotes = mkOption {
    type = types.attrsOf remoteType;
    default = { };
    description = "Flatpak remotes keyed by name. Flathub is merged by default.";
  };

  defaultOrigin = mkOption {
    type = types.str;
    default = "flathub";
    description = "Remote used when a package does not set origin.";
  };

  packages = mkOption {
    type = types.listOf packageType;
    default = [ ];
    description = "Flatpak applications installed into the ${installation} installation.";
  };

  runtimes = mkOption {
    type = types.listOf runtimeType;
    default = [ ];
    example = [ "org.freedesktop.Platform.VulkanLayer.MangoHud/x86_64/24.08" ];
    description = "Flatpak runtimes and extensions installed with exact architecture and branch identity.";
  };

  overrides = mkOption {
    type = types.either overridesSubmoduleType legacyOverridesType;
    default = {
      settings = { };
      files = [ ];
      writeMode = "replace";
      pruneRemoved = false;
      pruneAll = false;
    };
    description = "Declarative Flatpak overrides with merge and replace modes.";
  };

  uninstallUnmanaged = mkOption {
    type = types.bool;
    default = false;
    description = "Remove applications and remotes not declared by flatlock.";
  };

  uninstallUnused = mkOption {
    type = types.bool;
    default = false;
    description = "Remove unused runtimes after reconciliation.";
  };

  lockFile = mkOption {
    type = types.nullOr types.path;
    default = null;
    description = "Versioned commit lock file read during evaluation.";
  };

  configRepoPath = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Writable configuration repository used by the flatlock CLI.";
  };

  lockFileRelativePath = mkOption {
    type = types.str;
    default =
      if installation == "system" then "hosts/${hostname}/flatpak.lock" else "flatpak-user.lock";
    description = "Lock file path relative to configRepoPath.";
  };

  lockRuntimes = mkOption {
    type = types.bool;
    default = false;
    description = "Record, enforce, and mask runtime commits.";
  };

  bundleDir = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Archive used by flatlock bundle and as locked commit fallback.";
  };

  strictOverrides = mkOption {
    type = types.bool;
    default = false;
    description = "Expose the generated replacement overrides for immutable integration.";
  };

  overridesPackage = mkOption {
    type = types.package;
    readOnly = true;
    internal = true;
    description = "Rendered replacement override directory.";
  };

  update = {
    onActivation = mkOption {
      type = types.bool;
      default = false;
      description = "Update unpinned applications when the reconciliation service runs.";
    };
    auto = {
      enable = mkEnableOption "periodic updates for unpinned Flatpaks";
      onCalendar = mkOption {
        type = types.str;
        default = "weekly";
        description = "systemd OnCalendar expression for the update timer.";
      };
    };
  };

  activation.mode = mkOption {
    type = types.enum [
      "blocking"
      "background"
    ];
    default = "blocking";
    description = "Run reconciliation as part of activation or schedule it in the background.";
  };

  activation.failOnError = mkOption {
    type = types.bool;
    default = true;
    description = "Fail Home Manager activation when Flatpak reconciliation fails.";
  };

  restartOnFailure = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Restart reconciliation after a failure.";
    };
    delay = mkOption {
      type = types.str;
      default = "30s";
      description = "Delay before retrying reconciliation.";
    };
    exponentialBackoff = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Increase the restart delay after repeated failures.";
      };
      steps = mkOption {
        type = types.int;
        default = 8;
        description = "Number of restart delay steps.";
      };
      maxDelay = mkOption {
        type = types.str;
        default = "1h";
        description = "Maximum restart delay.";
      };
    };
  };
}
