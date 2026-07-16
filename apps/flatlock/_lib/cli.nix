{
  lib,
  writeShellApplication,
  writeText,
  flatpak,
  ostree,
  python3,
  hostname ? "unknown",
  installation ? "system",
  configRepoPath ? null,
  lockFileRelativePath ? "flatpak.lock",
  declaredApps ? [ ],
  declaredRuntimes ? [ ],
  pinRequestedApps ? [ ],
  pinRequestedRuntimes ? [ ],
  bundleApps ? [ ],
  declaredRemotes ? [ ],
  declaredRemoteDetails ? { },
  expectedOrigins ? { },
  overrideSettings ? { },
  overrideWriteMode ? "replace",
  uninstallUnmanaged ? false,
  lockRuntimes ? false,
  bundleDir ? null,
}:

let
  source = ./.;
  config = writeText "flatlock-${installation}-cli.json" (
    builtins.toJSON {
      inherit
        hostname
        installation
        configRepoPath
        lockFileRelativePath
        declaredApps
        declaredRuntimes
        pinRequestedApps
        pinRequestedRuntimes
        bundleApps
        declaredRemotes
        declaredRemoteDetails
        expectedOrigins
        overrideSettings
        overrideWriteMode
        uninstallUnmanaged
        lockRuntimes
        bundleDir
        ;
    }
  );
in
writeShellApplication {
  name = "flatlock";
  runtimeInputs = [
    flatpak
    ostree
    python3
  ];
  text = ''
    exec python3 ${source}/cli.py ${lib.escapeShellArg config} "$@"
  '';
}
