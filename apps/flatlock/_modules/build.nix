{
  config,
  lib,
  pkgs,
  installation,
  hostname,
  model,
}:

let
  cfg = config.flatlock;
  source = ../_lib;

  manifest = pkgs.writeText "flatlock-${installation}-manifest.json" (
    builtins.toJSON {
      inherit installation;
      remotes = model.remotesNormalized;
      apps = map (package: {
        id = package.appId;
        inherit (package)
          arch
          ref
          origin
          commit
          ;
        mask = package.ref;
        source = {
          kind = package.sourceKind;
          path = package.sourcePath;
        };
      }) model.resolved;
      runtimePackages = map (runtime: {
        id = runtime.id;
        inherit (runtime)
          ref
          origin
          commit
          ;
        mask = runtime.ref;
        source = {
          kind = "remote";
          path = null;
        };
      }) model.resolvedRuntimes;
      runtimes = lib.mapAttrsToList (ref: commit: { inherit ref commit; }) model.runtimeDependencyLocks;
      overrides = {
        settings = model.overrideSettings;
        inherit (model.overrideCfg)
          writeMode
          pruneRemoved
          pruneAll
          ;
      };
      inherit (cfg) bundleDir uninstallUnmanaged uninstallUnused;
      updateOnActivation = cfg.update.onActivation;
    }
  );

  reconciler = pkgs.writeShellApplication {
    name = "flatlock-reconcile";
    runtimeInputs = [
      pkgs.flatpak
      pkgs.python3
    ];
    text = ''
      exec python3 ${source}/reconcile.py "''${FLATLOCK_MANIFEST:-${manifest}}"
    '';
  };

  flatlock = pkgs.callPackage ../_lib/cli.nix {
    inherit hostname installation;
    inherit (cfg)
      bundleDir
      configRepoPath
      lockFileRelativePath
      lockRuntimes
      ;
    declaredApps = model.declaredRefs;
    declaredRuntimes = model.declaredRuntimeRefs;
    pinRequestedApps = map (package: package.ref) (
      builtins.filter (package: package.pinRequested) model.resolved
    );
    pinRequestedRuntimes = map (runtime: runtime.ref) (
      builtins.filter (runtime: runtime.pinRequested) model.resolvedRuntimes
    );
    bundleApps = map (package: package.ref) (
      builtins.filter (package: package.sourceKind == "bundle") model.resolved
    );
    declaredRemotes = builtins.attrNames model.remotesNormalized;
    declaredRemoteDetails = model.remotesNormalized;
    expectedOrigins = builtins.listToAttrs (
      map
        (item: {
          name = item.ref;
          value = item.origin;
        })
        (builtins.filter (package: package.sourceKind == "remote") model.resolved ++ model.resolvedRuntimes)
    );
    overrideSettings = model.overrideSettings;
    overrideWriteMode = model.overrideCfg.writeMode;
    inherit (cfg) uninstallUnmanaged;
  };

  restartConfig = lib.optionalAttrs cfg.restartOnFailure.enable (
    {
      Restart = "on-failure";
      RestartSec = cfg.restartOnFailure.delay;
    }
    // lib.optionalAttrs cfg.restartOnFailure.exponentialBackoff.enable {
      RestartSteps = cfg.restartOnFailure.exponentialBackoff.steps;
      RestartMaxDelaySec = cfg.restartOnFailure.exponentialBackoff.maxDelay;
    }
  );

  unpinned =
    map (package: package.ref) (
      builtins.filter (package: package.sourceKind != "bundle" && package.commit == null) model.resolved
    )
    ++ map (runtime: runtime.ref) (
      builtins.filter (runtime: runtime.commit == null) model.resolvedRuntimes
    );

  updateCommand =
    if unpinned == [ ] then
      "${pkgs.coreutils}/bin/echo 'flatlock: everything is locked, nothing to update'"
    else
      "${flatlock}/bin/flatlock update ${lib.escapeShellArgs unpinned}";
in
{
  inherit
    flatlock
    manifest
    reconciler
    restartConfig
    updateCommand
    ;
}
