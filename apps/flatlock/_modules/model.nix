{
  config,
  lib,
  pkgs,
  installation,
}:

let
  cfg = config.flatlock;
  ini = import ../_lib/ini.nix { inherit lib; };

  overrideCfg =
    if
      cfg.overrides ? settings
      || cfg.overrides ? files
      || cfg.overrides ? writeMode
      || cfg.overrides ? pruneRemoved
      || cfg.overrides ? pruneAll
    then
      cfg.overrides
    else
      {
        settings = cfg.overrides;
        files = [ ];
        writeMode = "replace";
        pruneRemoved = false;
        pruneAll = false;
      };

  isHttpUrl =
    value: builtins.isString value && (lib.hasPrefix "https://" value || lib.hasPrefix "http://" value);

  materialize =
    value: sha256:
    if builtins.isPath value then
      toString (
        builtins.path {
          path = value;
          name = baseNameOf (toString value);
        }
      )
    else if isHttpUrl value then
      if sha256 == null then
        throw "flatlock: HTTP bundle and flatpakref sources require sha256"
      else
        toString (
          builtins.fetchurl {
            url = value;
            inherit sha256;
          }
        )
    else
      toString value;

  originFromName =
    name:
    let
      parts = builtins.filter (part: part != "") (lib.splitString "." name);
    in
    lib.toLower (lib.last parts) + "-origin";

  validNamePart =
    value:
    builtins.isString value
    && value != ""
    && builtins.match "^[A-Za-z0-9_][A-Za-z0-9_-]*$" value != null;
  validAppId =
    value:
    let
      parts = lib.splitString "." value;
    in
    builtins.length parts >= 3 && lib.all validNamePart parts;
  validSimpleName =
    value:
    builtins.isString value
    && value != ""
    && builtins.match "^[A-Za-z0-9_][A-Za-z0-9_.-]*$" value != null;
  validCommit =
    value:
    builtins.isString value
    && builtins.stringLength value == 64
    && builtins.match "^[0-9a-fA-F]+$" value != null;
  validLockMap = value: builtins.isAttrs value && lib.all validCommit (builtins.attrValues value);
  validRelativePath =
    value:
    value != ""
    && !lib.hasPrefix "/" value
    && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" value);

  normalizePackage =
    value:
    let
      initial =
        if builtins.isString value then
          let
            parts = lib.splitString "//" value;
          in
          {
            appId = builtins.head parts;
            branch = if builtins.length parts > 1 then builtins.elemAt parts 1 else null;
            arch = null;
            origin = null;
            pin = true;
            commit = null;
            bundle = null;
            flatpakref = null;
            sha256 = null;
          }
        else
          value;
      sourceValue = if initial.bundle != null then initial.bundle else initial.flatpakref;
      sourcePath = if sourceValue == null then null else materialize sourceValue initial.sha256;
      metadataReadable =
        initial.flatpakref != null && (builtins.isPath initial.flatpakref || isHttpUrl initial.flatpakref);
      metadata =
        if metadataReadable then (ini.parse (builtins.readFile sourcePath))."Flatpak Ref" or { } else { };
      appId = initial.appId or null;
      metadataAppId = metadata.Name or null;
      metadataBranch = metadata.Branch or null;
      metadataArch = metadata.Arch or null;
      resolvedAppId = if appId != null then appId else metadataAppId;
      resolvedBranch = if initial.branch != null then initial.branch else metadataBranch;
      resolvedArch = if initial.arch != null then initial.arch else metadataArch;
      resolvedOrigin =
        if initial.origin != null then
          initial.origin
        else if initial.flatpakref != null && metadata ? SuggestRemoteName then
          metadata.SuggestRemoteName
        else if initial.flatpakref != null && resolvedAppId != null then
          originFromName resolvedAppId
        else
          cfg.defaultOrigin;
      sourceKind =
        if initial.bundle != null then
          "bundle"
        else if initial.flatpakref != null then
          "flatpakref"
        else
          "remote";
      ref =
        if resolvedAppId == null then
          ""
        else if resolvedArch != null && resolvedBranch != null then
          "${resolvedAppId}/${resolvedArch}/${resolvedBranch}"
        else if resolvedBranch != null then
          "${resolvedAppId}//${resolvedBranch}"
        else
          resolvedAppId;
    in
    initial
    // {
      inherit
        metadataAppId
        metadataBranch
        metadataArch
        sourcePath
        sourceKind
        ref
        ;
      appId = resolvedAppId;
      branch = resolvedBranch;
      arch = resolvedArch;
      origin = resolvedOrigin;
    };

  normalizeRuntime =
    value:
    let
      parts = if builtins.isString value then lib.splitString "/" value else [ ];
      initial =
        if builtins.isString value then
          {
            id = if parts == [ ] then "" else builtins.head parts;
            arch = if builtins.length parts == 3 then builtins.elemAt parts 1 else null;
            branch = if builtins.length parts == 3 then builtins.elemAt parts 2 else null;
            origin = null;
            pin = true;
            commit = null;
            syntaxValid = builtins.length parts == 3;
          }
        else
          value // { syntaxValid = true; };
      origin = if initial.origin != null then initial.origin else cfg.defaultOrigin;
      ref =
        if initial.id == "" || initial.arch == null || initial.branch == null then
          ""
        else
          "runtime/${initial.id}/${initial.arch}/${initial.branch}";
    in
    initial // { inherit origin ref; };

  normalized = map normalizePackage cfg.packages;
  declaredRefs = map (package: package.ref) normalized;
  normalizedRuntimes = map normalizeRuntime cfg.runtimes;
  declaredRuntimeRefs = map (runtime: runtime.ref) normalizedRuntimes;

  lockContent =
    if cfg.lockFile != null && builtins.pathExists cfg.lockFile then
      builtins.readFile cfg.lockFile
    else
      null;
  parsedLock =
    if lockContent == null || lockContent == "" then
      {
        success = true;
        value = { };
      }
    else
      let
        parsed = builtins.fromJSON lockContent;
      in
      builtins.tryEval (builtins.deepSeq parsed parsed);
  lockParsed = parsedLock.success && builtins.isAttrs parsedLock.value;
  rawLock = if lockParsed then parsedLock.value else { };
  versionedLock = rawLock ? version;
  rawLockApps = rawLock.apps or { };
  rawLockRuntimes = rawLock.runtimes or { };
  legacyLock = lib.filterAttrs (_: value: builtins.isString value) rawLock;
  lockApps =
    if versionedLock then
      if builtins.isAttrs rawLockApps then rawLockApps else { }
    else
      lib.filterAttrs (ref: _: builtins.elem ref declaredRefs) legacyLock;
  allLockRuntimes =
    if versionedLock then
      if builtins.isAttrs rawLockRuntimes then rawLockRuntimes else { }
    else if cfg.lockRuntimes then
      lib.filterAttrs (ref: _: !(builtins.elem ref declaredRefs)) legacyLock
    else
      { };
  lockRuntimes =
    if cfg.lockRuntimes then
      allLockRuntimes
    else
      lib.filterAttrs (ref: _: builtins.elem ref declaredRuntimeRefs) allLockRuntimes;

  resolved = map (
    package:
    package
    // {
      pinRequested = package.sourceKind != "bundle" && (package.pin || package.commit != null);
      commit =
        if package.sourceKind == "bundle" then
          null
        else if package.commit != null then
          package.commit
        else if package.pin then
          lockApps.${package.ref} or null
        else
          null;
    }
  ) normalized;
  resolvedRuntimes = map (
    runtime:
    runtime
    // {
      pinRequested = runtime.pin || runtime.commit != null;
      commit =
        if runtime.commit != null then
          runtime.commit
        else if runtime.pin then
          lockRuntimes.${runtime.ref} or null
        else
          null;
    }
  ) normalizedRuntimes;
  runtimeDependencyLocks = lib.filterAttrs (
    ref: _: !(builtins.elem ref declaredRuntimeRefs)
  ) lockRuntimes;

  remotesNormalized = lib.mapAttrs (
    _: value:
    if builtins.isString value then
      {
        location = value;
        gpgImport = null;
        extraArgs = [ ];
      }
    else
      {
        gpgImport = if value.gpgImport == null then null else materialize value.gpgImport null;
        extraArgs = [ ];
      }
      // builtins.removeAttrs value [ "gpgImport" ]
  ) cfg.remotes;

  overrideFileAttrs = builtins.listToAttrs (
    map (path: {
      name = baseNameOf (toString path);
      value = path;
    }) overrideCfg.files
  );
  overrideAppIds = lib.unique (
    builtins.attrNames overrideFileAttrs ++ builtins.attrNames overrideCfg.settings
  );
  overrideSettings = builtins.listToAttrs (
    map (
      appId:
      let
        fileBase =
          if overrideFileAttrs ? ${appId} then
            ini.parse (builtins.readFile overrideFileAttrs.${appId})
          else
            { };
        configured = overrideCfg.settings.${appId} or { };
        configuredSettings =
          if builtins.isPath configured then ini.parse (builtins.readFile configured) else configured;
      in
      {
        name = appId;
        value = ini.merge fileBase configuredSettings;
      }
    ) overrideAppIds
  );
  overrideFileNames = map (path: baseNameOf (toString path)) overrideCfg.files;

  overridesPackage = pkgs.linkFarm "flatlock-${installation}-overrides" (
    lib.mapAttrsToList (appId: settings: {
      name = appId;
      path = pkgs.writeText "flatlock-override-${appId}" (ini.render settings);
    }) overrideSettings
  );

  assertions = [
    {
      assertion = lockParsed;
      message = "flatlock lockFile must contain a JSON object.";
    }
    {
      assertion = !versionedLock || rawLock.version == 1;
      message = "flatlock lockFile uses an unsupported version.";
    }
    {
      assertion =
        if versionedLock then
          validLockMap rawLockApps && validLockMap rawLockRuntimes
        else
          validLockMap rawLock;
      message = "flatlock lock entries must be full 64 character hexadecimal commits.";
    }
    {
      assertion = lib.all (package: package.appId != null) normalized;
      message = "flatlock packages require appId unless it can be read from flatpakref.";
    }
    {
      assertion = lib.all (package: package.appId == null || validAppId package.appId) normalized;
      message = "flatlock package appId values must be valid reverse DNS identifiers.";
    }
    {
      assertion = lib.all (package: package.branch == null || validSimpleName package.branch) normalized;
      message = "flatlock package branch values contain invalid characters.";
    }
    {
      assertion = lib.all (package: package.arch == null || validSimpleName package.arch) normalized;
      message = "flatlock package architecture values contain invalid characters.";
    }
    {
      assertion = lib.all (package: package.arch == null || package.branch != null) normalized;
      message = "flatlock packages with an explicit architecture require a branch.";
    }
    {
      assertion = lib.all (package: validSimpleName package.origin) normalized;
      message = "flatlock package origin values contain invalid characters.";
    }
    {
      assertion = lib.all (
        package: package.metadataAppId == null || package.appId == package.metadataAppId
      ) normalized;
      message = "flatlock flatpakref appId does not match its Name metadata.";
    }
    {
      assertion = lib.all (
        package: package.metadataBranch == null || package.branch == package.metadataBranch
      ) normalized;
      message = "flatlock flatpakref branch does not match its Branch metadata.";
    }
    {
      assertion = lib.all (
        package: package.metadataArch == null || package.arch == package.metadataArch
      ) normalized;
      message = "flatlock flatpakref architecture does not match its Arch metadata.";
    }
    {
      assertion = lib.all (package: package.commit == null || validCommit package.commit) resolved;
      message = "flatlock package commits must be full 64 character hexadecimal values.";
    }
    {
      assertion = lib.allUnique declaredRefs;
      message = "flatlock packages contains duplicate refs.";
    }
    {
      assertion = lib.all (runtime: runtime.syntaxValid) normalizedRuntimes;
      message = "flatlock runtime strings must use ID/ARCH/BRANCH syntax.";
    }
    {
      assertion = lib.all (runtime: validAppId runtime.id) normalizedRuntimes;
      message = "flatlock runtime IDs must be valid reverse DNS identifiers.";
    }
    {
      assertion = lib.all (
        runtime: runtime.arch != null && validSimpleName runtime.arch
      ) normalizedRuntimes;
      message = "flatlock runtimes require a valid architecture.";
    }
    {
      assertion = lib.all (
        runtime: runtime.branch != null && validSimpleName runtime.branch
      ) normalizedRuntimes;
      message = "flatlock runtimes require a valid branch.";
    }
    {
      assertion = lib.all (runtime: validSimpleName runtime.origin) normalizedRuntimes;
      message = "flatlock runtime origin values contain invalid characters.";
    }
    {
      assertion = lib.all (
        runtime: runtime.commit == null || validCommit runtime.commit
      ) resolvedRuntimes;
      message = "flatlock runtime commits must be full 64 character hexadecimal values.";
    }
    {
      assertion = lib.allUnique declaredRuntimeRefs;
      message = "flatlock runtimes contains duplicate refs.";
    }
    {
      assertion = lib.all (package: !(package.bundle != null && package.flatpakref != null)) normalized;
      message = "flatlock packages cannot combine bundle and flatpakref.";
    }
    {
      assertion = lib.all (package: package.bundle == null || package.commit == null) normalized;
      message = "flatlock packages cannot combine bundle and commit.";
    }
    {
      assertion = lib.allUnique overrideFileNames;
      message = "flatlock override file basenames must be unique.";
    }
    {
      assertion = lib.all (appId: appId == "global" || validAppId appId) overrideAppIds;
      message = "flatlock override names must be global or valid application IDs.";
    }
    {
      assertion = lib.all validSimpleName (builtins.attrNames cfg.remotes);
      message = "flatlock remote names contain invalid characters.";
    }
    {
      assertion = validRelativePath cfg.lockFileRelativePath;
      message = "flatlock lockFileRelativePath must be a normalized relative path.";
    }
    {
      assertion = cfg.configRepoPath == null || lib.hasPrefix "/" cfg.configRepoPath;
      message = "flatlock configRepoPath must be absolute.";
    }
    {
      assertion = cfg.bundleDir == null || lib.hasPrefix "/" cfg.bundleDir;
      message = "flatlock bundleDir must be absolute.";
    }
    {
      assertion = !cfg.strictOverrides || overrideCfg.writeMode == "replace";
      message = "flatlock strictOverrides requires overrides.writeMode = replace.";
    }
    {
      assertion = !cfg.update.auto.enable || cfg.configRepoPath != null;
      message = "flatlock automatic updates require configRepoPath so the lock can be updated.";
    }
  ];

  warnings =
    lib.optional (
      cfg.lockFile == null
      && (
        lib.any (package: package.pinRequested && package.commit == null) resolved
        || lib.any (runtime: runtime.pinRequested && runtime.commit == null) resolvedRuntimes
      )
    ) "flatlock: lockFile is unset so requested pins install latest."
    ++ lib.optional (
      cfg.lockFile != null && !builtins.pathExists cfg.lockFile
    ) "flatlock: lockFile is missing from the evaluated source."
    ++ lib.optional (
      !versionedLock && rawLock != { }
    ) "flatlock: legacy lock format loaded. Run flatlock lock to migrate it.";
in
{
  inherit
    assertions
    declaredRefs
    declaredRuntimeRefs
    lockRuntimes
    overrideCfg
    overrideSettings
    overridesPackage
    remotesNormalized
    resolved
    resolvedRuntimes
    runtimeDependencyLocks
    warnings
    ;
}
