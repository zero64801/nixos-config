{ config, lib, pkgs, ... }:

let
  cfg = config.my.confine;

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
        description = "Keep the private home across reboots on an impermanent host.";
      };
    };
  };

  wrapped = lib.mapAttrs (
    name: app: wrap (removeAttrs app [ "install" "persist" ] // { name = app.name or name; })
  ) cfg.apps;

  # Read merged permissions, raw attrs miss values a profile supplied.
  permsOf = name: wrapped.${name}.permissions;

  privateHomes = lib.filter (name: cfg.apps.${name}.persist && (permsOf name).home == "private") (
    lib.attrNames cfg.apps
  );
in
{
  options.my.confine = {
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
  };

  config = {
    my.confine.packages = wrapped;

    environment.systemPackages =
      lib.attrValues (lib.filterAttrs (name: _: cfg.apps.${name}.install) wrapped)
      ++ lib.optional (cfg.apps != { }) importTool;

    my.persistence.home.directories = map (
      name: ".local/share/confine/${(permsOf name).appId}"
    ) privateHomes;

    assertions = lib.concatLists (
      lib.mapAttrsToList (name: app: [
        {
          # xwayland-satellite is itself a Wayland client, so isolated X11 needs wayland.
          assertion = (permsOf name).x11 != "isolated" || (permsOf name).wayland;
          message = "my.confine.apps.${name}: x11 = \"isolated\" needs wayland = true.";
        }
        {
          # Closed charset, the id also names paths and is interpolated into the launcher.
          assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+)+" app.appId != null;
          message = "my.confine.apps.${name}: appId ${app.appId} must be reverse-DNS, e.g. com.vendor.App.";
        }
        {
          # The a11y bus rides the dbus proxy, without it the bus silently vanishes.
          assertion = (permsOf name).dbus.filter || !(permsOf name).a11y;
          message = "my.confine.apps.${name}: a11y needs dbus.filter = true, the proxy is what carries it.";
        }
        {
          # The unfiltered path binds only the session bus, system rules would silently no-op.
          assertion =
            (permsOf name).dbus.filter
            || ((permsOf name).dbus.system.talk == [ ] && (permsOf name).dbus.system.call == [ ]);
          message = "my.confine.apps.${name}: dbus.system rules need dbus.filter = true.";
        }
        {
          # Home and runtime dir are keyed on appId, a shared id merges two sandboxes.
          assertion =
            lib.length (lib.filter (other: other.appId == app.appId) (lib.attrValues cfg.apps)) == 1;
          message = "my.confine.apps.${name}: appId ${app.appId} is used by more than one app.";
        }
      ]) cfg.apps
    );

    warnings = lib.concatLists (
      lib.mapAttrsToList (
        name: _:
        let
          p = permsOf name;
        in
        lib.optional (p.home == "host")
          "my.confine.apps.${name}: home = \"host\" gives the app the whole home directory."
        ++ lib.optional (!p.seccomp.enable)
          "my.confine.apps.${name}: seccomp is off, so terminal injection and the namespace group are unfiltered."
        # X abstract sockets are netns scoped, host networking bypasses any x11 setting.
        ++ lib.optional (p.network == "host" || p.network == true)
          "my.confine.apps.${name}: network = \"host\" also exposes host abstract sockets, including the real X server."
      ) cfg.apps
    );
  };
}
