# nix eval --impure --raw --expr 'import ./apps/confine/_tests/module.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

let
  inherit (pkgs) lib;

  evalWith =
    apps:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        ../default.nix
        (
          { lib, ... }:
          {
            options.my.persistence.home.directories = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            config = {
              # confine-import is built from the repo's own util scaffold.
              nixpkgs.pkgs = pkgs.extend (import ../../../pkgs/functions.nix null);
              boot.loader.grub.devices = [ "nodev" ];
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = "25.11";
              my.confine.apps = apps;
            };
          }
        )
      ];
    }).config;

  failures = apps: map (a: a.message) (lib.filter (a: !a.assertion) (evalWith apps).assertions);
  warnings = apps: (evalWith apps).warnings;

  plain = {
    package = pkgs.hello;
    appId = "com.vendor.App";
  };

  anyMatching = pattern: msgs: lib.any (m: lib.hasInfix pattern m) msgs;

  checks = {
    # readOnly plus a default counts as two definitions and threw on read.
    packagesIsReadable = (evalWith { a = plain; }).my.confine.packages ? a;

    # The assertion must read merged perms, wayland can come from a profile.
    isolatedX11WithProfileWayland =
      failures {
        a = plain // {
          profile = [ "gui" ];
          x11 = "isolated";
        };
      } == [ ];

    isolatedX11WithoutWaylandRejected = anyMatching "needs wayland" (
      failures { a = plain // { x11 = "isolated"; }; }
    );

    # The id names the private home, sharing one silently merges two sandboxes.
    duplicateAppIdRejected = anyMatching "used by more than one" (
      failures {
        a = plain;
        b = plain;
      }
    );

    # wrap throws on a bad id before assertions are collected, hence tryEval.
    appIdCharacterSetEnforced =
      !(builtins.tryEval (failures { a = plain // { appId = "com.v.A;rm -rf /"; }; })).success
      && !(builtins.tryEval (failures { a = plain // { appId = "nodots"; }; })).success
      && failures { a = plain // { appId = "com.vendor.App-2"; }; } == [ ];

    # Both ride on the bus proxy, without it they would look granted and do nothing.
    a11yNeedsTheProxy = anyMatching "a11y needs dbus.filter" (
      failures {
        a = plain // {
          a11y = true;
          dbus.filter = false;
        };
      }
    );

    systemBusNeedsTheProxy = anyMatching "dbus.system rules need" (
      failures {
        a = plain // {
          dbus.filter = false;
          dbus.system.talk = [ "org.example.Thing" ];
        };
      }
    );

    # Weakenings warn rather than fail, since each is sometimes the right call.
    hostHomeWarns = anyMatching "whole home directory" (
      warnings { a = plain // { home = "host"; }; }
    );

    seccompOffWarns = anyMatching "seccomp is off" (
      warnings { a = plain // { seccomp.enable = false; }; }
    );

    # X servers also listen on abstract sockets, which follow the network namespace.
    hostNetworkWarnsAboutX11 = anyMatching "abstract sockets" (
      warnings { a = plain // { network = "host"; }; }
    );

    persistenceCoversPrivateHomesOnly =
      (evalWith { a = plain; }).my.persistence.home.directories == [ ".local/share/confine/com.vendor.App" ]
      && (evalWith { a = plain // { home = "host"; }; }).my.persistence.home.directories == [ ]
      && (evalWith { a = plain // { persist = false; }; }).my.persistence.home.directories == [ ];

    # install = false keeps it out of the system profile but still wrapped.
    installIsRespected =
      lib.length (evalWith { a = plain // { install = false; }; }).environment.systemPackages
      < lib.length (evalWith { a = plain; }).environment.systemPackages;

    validConfigIsSilent = failures { a = plain; } == [ ] && warnings { a = plain; } == [ ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
if failed == [ ] then
  "ok: ${toString (lib.length (lib.attrNames checks))} module checks passed"
else
  throw "confine module tests failed: ${lib.concatStringsSep ", " failed}"
