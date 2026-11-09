{ config, lib, pkgs, ... }:

let
  cfg = config.confine;

  wrap = pkgs.callPackage ./_lib/wrap.nix { };
  importTool = pkgs.callPackage ./_lib/import.nix { };
  profileNames = lib.attrNames (import ./_lib/profiles.nix);

  # Freeform: declaring each toggle as an option would block profiles from adding to it.
  appType = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;

    options = {
      package = lib.mkOption {
        type = lib.types.package;
        description = "Package to wrap. Its entry points are replaced by sandboxed ones.";
      };

      appId = lib.mkOption {
        type = lib.types.str;
        example = "com.discordapp.Discord";
        description = ''
          Reverse-DNS identity. xdg-desktop-portal keys an application's
          permissions on it and it names the private home, so changing it
          hands the app an empty profile.
        '';
      };

      profile = lib.mkOption {
        type = lib.types.listOf (lib.types.enum profileNames);
        default = [ ];
        example = [
          "gui"
          "audio"
        ];
        description = "Permission presets merged underneath whatever the app sets by hand.";
      };

      install = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add the wrapped package to environment.systemPackages.";
      };

      persist = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "List the private home in persistentHomeDirectories, for an impermanent host to keep across reboots.";
      };

      silenceWarnings = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "home" "seccomp" "network" "wayland" ]);
        default = [ ];
        example = [ "network" ];
        description = "Build warnings this app accepts on purpose, so rebuilds stop printing them.";
      };
    };
  };

  wrapped = lib.mapAttrs (
    name: app:
    wrap (removeAttrs app [ "install" "persist" "silenceWarnings" ] // { name = app.name or name; })
  ) cfg.apps;

  # Read merged permissions, raw attrs miss values a profile supplied.
  permsOf = name: wrapped.${name}.permissions;

  privateHomes = lib.filter (name: cfg.apps.${name}.persist && (permsOf name).home == "private") (
    lib.attrNames cfg.apps
  );

  # What confine info and run read: each app's launcher, default command and merged permissions.
  index = pkgs.writeText "confine-apps.json" (
    builtins.toJSON (
      lib.mapAttrs (
        _: w:
        let
          p = w.permissions;
          main =
            if p.binaries != null then
              lib.head p.binaries
            else
              p.package.meta.mainProgram or (lib.getName p.package);
        in
        {
          inherit (p) appId;
          launcher = "${w.launcher}/bin/${w.launcher.name}";
          main = "${p.package}/bin/${main}";
          permissions = removeAttrs p [ "package" ];
        }
      ) wrapped
    )
  );

  cli = pkgs.callPackage ./_lib/cli.nix {
    inherit index;
    helpers = pkgs.callPackage ./_lib/helpers.nix { };
  };
in
{
  options.confine = {
    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = { };
      description = "Applications to run under a bubblewrap sandbox.";
    };

    packages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      # No default, readOnly plus a default throws once config sets it.
      readOnly = true;
      description = ''
        The wrapped packages, keyed as declared. Read this when something other
        than systemPackages has to be handed the sandboxed build, as Home
        Manager program modules do.
      '';
    };

    persistentHomeDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # No default, readOnly plus a default throws once config sets it.
      readOnly = true;
      description = ''
        Home directories, relative to HOME, that hold the private homes of apps
        with persist = true. Hand them to whatever keeps state across reboots
        on an impermanent system.
      '';
    };

    lib = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      # No default, readOnly plus a default throws once config sets it.
      readOnly = true;
      description = ''
        Builders for sandboxes that confine.apps does not cover. wrap takes the
        attributes of an app and returns the wrapped package, whose launcher
        runs any command in that sandbox. seccomp takes filter flags and
        returns a BPF program for bwrap --seccomp.
      '';
    };
  };

  config = {
    confine.packages = wrapped;
    confine.lib = {
      inherit wrap;
      seccomp = pkgs.callPackage ./_lib/seccomp.nix { };
    };

    environment.systemPackages =
      lib.attrValues (lib.filterAttrs (name: _: cfg.apps.${name}.install) wrapped)
      ++ lib.optionals (cfg.apps != { }) [
        importTool
        cli
      ];

    confine.persistentHomeDirectories = map (name: ".local/share/confine/${(permsOf name).appId}") privateHomes;

    assertions = lib.concatLists (
      lib.mapAttrsToList (name: app: [
        {
          assertion = (permsOf name).x11 != "isolated" || (permsOf name).wayland;
          message = "confine.apps.${name}: x11 = \"isolated\" needs wayland = true.";
        }
        {
          assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+)+" app.appId != null;
          message = "confine.apps.${name}: appId ${app.appId} must be reverse-DNS, e.g. com.vendor.App.";
        }
        {
          assertion = (permsOf name).dbus.filter || !(permsOf name).a11y;
          message = "confine.apps.${name}: a11y needs dbus.filter = true, the proxy is what carries it.";
        }
        {
          assertion =
            (permsOf name).dbus.filter
            || ((permsOf name).dbus.system.talk == [ ] && (permsOf name).dbus.system.call == [ ]);
          message = "confine.apps.${name}: dbus.system rules need dbus.filter = true.";
        }
        {
          assertion =
            lib.length (lib.filter (other: other.appId == app.appId) (lib.attrValues cfg.apps)) == 1;
          message = "confine.apps.${name}: appId ${app.appId} is used by more than one app.";
        }
      ]) cfg.apps
    );

    warnings = lib.concatLists (
      lib.mapAttrsToList (
        name: app:
        let
          p = permsOf name;
          warn = kind: cond: msg: lib.optional (cond && !lib.elem kind app.silenceWarnings) "confine.apps.${name}: ${msg}";
        in
        warn "home" (p.home == "host") "home = \"host\" gives the app the whole home directory."
        ++ warn "seccomp" (!p.seccomp.enable)
          "seccomp is off, so terminal injection and the namespace group are unfiltered."
        ++ warn "network" (p.network == "host" || p.network == true)
          "network = \"host\" also exposes host abstract sockets, including the real X server."
        ++ warn "wayland" ((p.wayland || p.x11 == "isolated") && !p.waylandSecurityContext)
          "without a Wayland security context the compositor offers fake input, screen capture and background clipboard reads."
      ) cfg.apps
    );
  };
}
