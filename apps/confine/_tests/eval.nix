# nix eval --impure --raw --expr 'import ./apps/confine/_tests/eval.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

let
  inherit (pkgs) lib;
  wrap = pkgs.callPackage ../_lib/wrap.nix { };

  build = settings: wrap ({ package = pkgs.hello; appId = "org.test.App"; } // settings);

  perms = settings: (build settings).permissions;
  filterName = settings: (build settings).filter.name;
  sessionRules = settings: (build settings).dbusArgs.session;

  bare = perms { };
  withProfiles = perms {
    profile = [
      "gui"
      "chromium"
    ];
    dbus.session.talk = [ "org.example.Extra" ];
  };

  checks = {
    closedByDefault =
      !bare.network
      && !bare.wayland
      && !bare.gpu
      && !bare.sysfs
      && bare.x11 == "none"
      && bare.home == "private"
      && bare.devices == [ ];

    strictSeccompByDefault =
      bare.seccomp.enable && !bare.seccomp.nesting && filterName { } == "confine-filter-strict.bpf";

    profileListsConcatenate =
      lib.elem "org.freedesktop.Notifications" withProfiles.dbus.session.talk
      && lib.elem "org.freedesktop.ScreenSaver" withProfiles.dbus.session.talk
      && lib.elem "org.example.Extra" withProfiles.dbus.session.talk;

    portalNamesAreNotTalkable =
      !lib.any (lib.hasPrefix "org.freedesktop.portal.") (perms { profile = [ "gui" ]; }).dbus.session.talk
      && lib.elem "--call=org.freedesktop.portal.*=*" (sessionRules { profile = [ "gui" ]; });

    profileScalarsApply = withProfiles.wayland && withProfiles.portals;

    nestingReachesFilter =
      withProfiles.seccomp.nesting
      && filterName { profile = [ "chromium" ]; } == "confine-filter-allow-nesting.bpf";

    steamProfileIsMultiarch =
      (perms { profile = [ "steam" ]; }).seccomp.multiarch
      && filterName { profile = [ "steam" ]; }
         == "confine-filter-allow-nesting-multiarch-allow-bluetooth.bpf";

    appOverridesProfile =
      !(perms {
        profile = [ "gui" ];
        portals = false;
      }).portals;

    unknownProfileThrows = !(builtins.tryEval (perms { profile = [ "nope" ]; })).success;

    envPassthroughRejectsBadName =
      !(builtins.tryEval (build { envPassthrough = [ "not-a-var" ]; }).drvPath).success;

    binPrefixRejectsBadChars =
      !(builtins.tryEval (build { binPrefix = "no spaces"; }).drvPath).success;

    symlinksRejectBareStrings =
      !(builtins.tryEval (build { symlinks = [ "xdg-run/discord-ipc-0" ]; }).drvPath).success;

    runtimeDirIsPrivateByDefault =
      bare.runtimeDir == "private"
      && !(builtins.tryEval (build { runtimeDir = "sideways"; }).drvPath).success;

    # Without the broadcast rule portal requests hang waiting for the Response signal.
    portalRepliesCanReturn = lib.elem "--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*" (
      sessionRules { profile = [ "gui" ]; }
    );

    ownsItsOwnNames =
      lib.elem "--own=org.test.App" (sessionRules { })
      && lib.elem "--own=org.mpris.MediaPlayer2.org.test.App.*" (sessionRules { });

    # libdrm resolves card nodes through sysfs, without it Vulkan enumerates no devices.
    gpuImpliesSysfs = (perms { profile = [ "gpu" ]; }).sysfs;

    x11StaysOffUnderGui = (perms { profile = [ "gui" ]; }).x11 == "none";

    networkClosedByDefault = bare.network == false;

    networkPortsAreSelective =
      bare.networkPorts.toHost == [ ]
      && (perms {
        network = "isolated";
        networkPorts.toHost = [ 6463 ];
      }).networkPorts.toHost == [ 6463 ];

    # A setup runs as root of pasta's namespace, without one it would run on the host.
    networkSetupsNeedIsolatedNetwork =
      !(builtins.tryEval (build { networkSetups.tun = "/bin/true"; }).drvPath).success
      && (builtins.tryEval (build {
        network = "isolated";
        networkSetups.tun = "/bin/true";
      }).drvPath).success;

    networkSetupsRejectBadNames =
      !(builtins.tryEval (build {
        network = "isolated";
        networkSetups."a)b" = "/bin/true";
      }).drvPath).success;

    # The a11y bus carries keystrokes, so gui must not drag it in.
    a11yIsOptIn = !bare.a11y && !(perms { profile = [ "gui" ]; }).a11y && (perms { profile = [ "a11y" ]; }).a11y;

    cameraNeedsNoDeviceNode = (perms { profile = [ "gui" ]; }).devices == [ ];

    isolatedNetworkKeepsPastaNamespace =
      (perms { network = "isolated"; }).network == "isolated"
      && !(builtins.tryEval (build { network = "sideways"; }).drvPath).success;

    everyProfileIsUsable =
      let
        names = lib.attrNames (import ../_lib/profiles.nix);
        strip = p: removeAttrs p [ "package" "name" ];
        baseline = strip bare;
      in
      names != [ ]
      && lib.all (
        p: (build { profile = [ p ]; }).drvPath != null && strip (perms { profile = [ p ]; }) != baseline
      ) names;

    unfilteredBusStillBuilds = (build { dbus.filter = false; }).drvPath != null;

    # The Flatpak portal's Spawn is a process-spawning primitive outside the sandbox.
    guiDoesNotGrantTheFlatpakPortal =
      !lib.elem "org.freedesktop.portal.Flatpak" (perms { profile = [ "gui" ]; }).dbus.session.talk;

    bindsCanBeRemapped =
      (build {
        binds.rw = [
          {
            from = "/mnt/storage/games";
            to = "Games";
          }
        ];
      }).drvPath != null;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
if failed == [ ] then
  "ok: ${toString (lib.length (lib.attrNames checks))} checks passed"
else
  throw "confine eval tests failed: ${lib.concatStringsSep ", " failed}"
