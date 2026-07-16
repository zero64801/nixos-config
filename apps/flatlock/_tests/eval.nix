{ pkgs, nixosSystem }:

let
  inherit (pkgs) lib;
  configuration =
    flatlock:
    nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../default.nix
        {
          boot.loader.grub.devices = [ "nodev" ];
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          networking.hostName = "flatlock-eval";
          system.stateVersion = "25.11";
          xdg.portal = {
            enable = true;
            extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
            config.common.default = "gtk";
          };
          flatlock = {
            enable = true;
            restartOnFailure.enable = false;
          }
          // flatlock;
        }
      ];
    };
  evaluate =
    flatlock: builtins.tryEval ((configuration flatlock).config.system.build.toplevel.drvPath);
  valid = evaluate {
    packages = [ "org.test.Valid" ];
    configRepoPath = "/etc/nixos";
  };
  validArchitecture = evaluate {
    packages = [
      {
        appId = "org.test.Arch";
        arch = "x86_64";
        branch = "stable";
      }
    ];
    configRepoPath = "/etc/nixos";
  };
  validRuntime = evaluate {
    runtimes = [ "org.test.Extension/x86_64/stable" ];
    configRepoPath = "/etc/nixos";
  };
  invalidRuntime = evaluate {
    runtimes = [ "org.test.Extension//stable" ];
  };
  invalidCommit = evaluate {
    packages = [
      {
        appId = "org.test.InvalidCommit";
        commit = "deadbeef";
      }
    ];
  };
  invalidAppId = evaluate {
    packages = [ "../invalid" ];
  };
  invalidArchitecture = evaluate {
    packages = [
      {
        appId = "org.test.InvalidArch";
        arch = "../x86_64";
        branch = "stable";
      }
    ];
  };
  architectureWithoutBranch = evaluate {
    packages = [
      {
        appId = "org.test.MissingBranch";
        arch = "x86_64";
      }
    ];
  };
  invalidRemote = evaluate {
    remotes."--invalid" = "https://example.invalid/repo.flatpakrepo";
  };
  invalidLockPath = evaluate {
    lockFileRelativePath = "../flatpak.lock";
  };
  invalidLockSchema = evaluate {
    lockFile = ./fixtures/invalid.lock;
  };
  unsupportedLock = evaluate {
    lockFile = ./fixtures/unsupported.lock;
  };
  mismatchedFlatpakref = evaluate {
    packages = [
      {
        appId = "org.test.Other";
        flatpakref = ./fixtures/org.test.Ref.flatpakref;
      }
    ];
  };
  background =
    (configuration {
      activation.mode = "background";
    }).config;
in
assert valid.success;
assert validArchitecture.success;
assert validRuntime.success;
assert !invalidRuntime.success;
assert !invalidCommit.success;
assert !invalidAppId.success;
assert !invalidArchitecture.success;
assert !architectureWithoutBranch.success;
assert !invalidRemote.success;
assert !invalidLockPath.success;
assert !invalidLockSchema.success;
assert !unsupportedLock.success;
assert !mismatchedFlatpakref.success;
assert background.systemd.services.flatlock.wantedBy == [ ];
assert background.systemd.timers.flatlock.wantedBy == [ "timers.target" ];
pkgs.runCommand "flatlock-evaluation-tests" { } ''
  touch $out
''
