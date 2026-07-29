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

    # Portal access needs only the call rule, --talk would be strictly broader.
    portalNamesAreNotTalkable =
      !lib.any (lib.hasPrefix "org.freedesktop.portal.") (perms { profile = [ "gui" ]; }).dbus.session.talk
      && lib.elem "--call=org.freedesktop.portal.*=*" (sessionRules { profile = [ "gui" ]; });

    profileScalarsApply = withProfiles.wayland && withProfiles.portals;

    # Electron's zygote needs the namespace, and that has to reach the filter.
    nestingReachesFilter =
      withProfiles.seccomp.nesting
      && filterName { profile = [ "chromium" ]; } == "confine-filter-allow-nesting.bpf";

    # 32-bit games need the second arch token or the filter misses them.
    steamProfileIsMultiarch =
      (perms { profile = [ "steam" ]; }).seccomp.multiarch
      && filterName { profile = [ "steam" ]; }
         == "confine-filter-allow-nesting-multiarch-allow-bluetooth.bpf";

    appOverridesProfile =
      !(perms {
        profile = [ "gui" ];
        portals = false;
      }).portals;

    # A typo in a profile name is a build failure, not a silently open sandbox.
    unknownProfileThrows = !(builtins.tryEval (perms { profile = [ "nope" ]; })).success;

    # The names land in the launcher's copy loop, anything else must be rejected.
    envPassthroughRejectsBadName =
      !(builtins.tryEval (build { envPassthrough = [ "not-a-var" ]; }).drvPath).success;

    # The prefix lands in file names and Exec lines, anything else must be rejected.
    binPrefixRejectsBadChars =
      !(builtins.tryEval (build { binPrefix = "no spaces"; }).drvPath).success;

    # Without the broadcast rule portal requests hang waiting for the Response signal.
    portalRepliesCanReturn = lib.elem "--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*" (
      sessionRules { profile = [ "gui" ]; }
    );

    # Without --own of its name, single-instance handoff and MPRIS registration fail.
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

    # The a11y bus carries keystrokes, so gui must not drag it in.
    a11yIsOptIn = !bare.a11y && !(perms { profile = [ "gui" ]; }).a11y && (perms { profile = [ "a11y" ]; }).a11y;

    # The Camera portal rides on portal.Desktop, no raw /dev/video node is needed.
    cameraNeedsNoDeviceNode = (perms { profile = [ "gui" ]; }).devices == [ ];

    # Isolated mode must reach bwrap as --share-net to stay in pasta's namespace.
    isolatedNetworkKeepsPastaNamespace =
      (perms { network = "isolated"; }).network == "isolated"
      # drvPath forces the launcher, where an unknown mode is rejected.
      && !(builtins.tryEval (build { network = "sideways"; }).drvPath).success;

    # A stale or renamed permission key would leave a profile that grants nothing.
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

    # The only path that never starts a proxy, nothing else exercises it.
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
