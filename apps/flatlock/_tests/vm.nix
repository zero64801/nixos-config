{ homeManagerModule }:
{ pkgs, lib, ... }:

let
  testRepo =
    pkgs.runCommand "flatlock-test-repo"
      {
        nativeBuildInputs = [
          pkgs.flatpak
          pkgs.ostree
          pkgs.jq
        ];
      }
      ''
        export HOME=$TMPDIR
        mkdir -p $out/repo runtime/files app/files app/export

        printf '[Runtime]\nname=org.test.Platform\nruntime=org.test.Platform/x86_64/stable' \
          > runtime/metadata
        ostree init --repo=$out/repo --mode=archive-z2

        commit() {
          ostree commit --repo=$out/repo --branch="$1" --owner-uid=0 --owner-gid=0 \
            --no-xattrs --canonical-permissions \
            --add-metadata-string=xa.metadata="$(cat "$2/metadata")" "$2"
        }

        echo runtime-v1 > runtime/files/marker
        commit runtime/org.test.Platform/x86_64/stable runtime
        runtime_v1=$(ostree rev-parse --repo=$out/repo runtime/org.test.Platform/x86_64/stable)

        echo runtime-v2 > runtime/files/marker
        commit runtime/org.test.Platform/x86_64/stable runtime
        runtime_v2=$(ostree rev-parse --repo=$out/repo runtime/org.test.Platform/x86_64/stable)

        printf '[Runtime]\nname=org.test.Extension\nruntime=org.test.Platform/x86_64/stable' \
          > runtime/metadata
        echo extension-v1 > runtime/files/marker
        commit runtime/org.test.Extension/x86_64/stable runtime
        extension_v1=$(ostree rev-parse --repo=$out/repo runtime/org.test.Extension/x86_64/stable)

        prepare_app() {
          printf '[Application]\nname=%s\nruntime=org.test.Platform/x86_64/stable\ncommand=true' "$1" \
            > app/metadata
          echo "$2" > app/files/version
        }

        prepare_app org.test.App app-v1
        commit app/org.test.App/x86_64/stable app
        app_v1=$(ostree rev-parse --repo=$out/repo app/org.test.App/x86_64/stable)
        prepare_app org.test.App app-v2
        commit app/org.test.App/x86_64/stable app
        app_v2=$(ostree rev-parse --repo=$out/repo app/org.test.App/x86_64/stable)

        prepare_app org.test.Ref ref-v1
        commit app/org.test.Ref/x86_64/stable app

        prepare_app org.test.User user-v1
        commit app/org.test.User/x86_64/stable app

        prepare_app org.test.Branch branch-stable
        commit app/org.test.Branch/x86_64/stable app
        branch_stable=$(ostree rev-parse --repo=$out/repo app/org.test.Branch/x86_64/stable)
        prepare_app org.test.Branch branch-beta
        commit app/org.test.Branch/x86_64/beta app

        prepare_app org.test.Bundle bundle-v1
        commit app/org.test.Bundle/x86_64/stable app
        bundle_v1=$(ostree rev-parse --repo=$out/repo app/org.test.Bundle/x86_64/stable)
        flatpak build-update-repo $out/repo
        flatpak build-bundle $out/repo $out/bundle-v1.flatpak org.test.Bundle stable

        prepare_app org.test.Bundle bundle-v2
        commit app/org.test.Bundle/x86_64/stable app
        bundle_v2=$(ostree rev-parse --repo=$out/repo app/org.test.Bundle/x86_64/stable)
        flatpak build-update-repo $out/repo
        flatpak build-bundle $out/repo $out/bundle-v2.flatpak org.test.Bundle stable

        printf '[Flatpak Repo]\nTitle=Flatlock Test\nUrl=file://%s/repo\nGPGVerify=false\n' \
          "$out" > $out/local.flatpakrepo

        jq -n \
          --arg app_v1 "$app_v1" \
          --arg app_v2 "$app_v2" \
          --arg branch_stable "$branch_stable" \
          --arg bundle_v1 "$bundle_v1" \
          --arg bundle_v2 "$bundle_v2" \
          --arg extension_v1 "$extension_v1" \
          --arg runtime_v1 "$runtime_v1" \
          --arg runtime_v2 "$runtime_v2" \
          '$ARGS.named' > $out/commits.json
      '';

  flatpakref = ./fixtures/org.test.Ref.flatpakref;

  emptyCli = pkgs.callPackage ../_lib/cli.nix {
    hostname = "machine";
    installation = "system";
    configRepoPath = null;
    declaredApps = [ ];
    pinRequestedApps = [ ];
    bundleApps = [ ];
  };
in
{
  name = "flatlock";

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ ../default.nix ];

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 6144;
    environment.etc."flatlock-test-repo".source = "${testRepo}/repo";
    environment.etc."flatlock-test-repo.flatpakrepo".source = "${testRepo}/local.flatpakrepo";
    users.users.owner = {
      isNormalUser = true;
      uid = 1001;
    };
    systemd.tmpfiles.rules = [
      "d /home/owner/cfg 0755 owner users - -"
      "d /home/owner/cfg/hosts 0755 owner users - -"
      "d /home/owner/cfg/hosts/machine 0755 owner users - -"
      "f /home/owner/cfg/hosts/machine/flatpak.lock 0644 owner users - -"
    ];

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = "gtk";
    };

    flatlock = {
      enable = true;
      defaultOrigin = "local";
      remotes = lib.mkForce {
        local = {
          location = "file://${testRepo}/local.flatpakrepo";
          extraArgs = [ "--no-gpg-verify" ];
        };
        alternate = {
          location = "file://${testRepo}/local.flatpakrepo";
          extraArgs = [ "--no-gpg-verify" ];
        };
      };
      packages = [
        "org.test.App"
        {
          inherit flatpakref;
          pin = false;
        }
        {
          appId = "org.test.Bundle";
          branch = "stable";
          bundle = "${testRepo}/bundle-v1.flatpak";
          pin = false;
        }
        {
          appId = "org.test.Branch";
          arch = "x86_64";
          branch = "stable";
        }
        {
          appId = "org.test.Branch";
          branch = "beta";
          pin = false;
        }
      ];
      runtimes = [ "org.test.Extension/x86_64/stable" ];
      overrides = {
        settings."org.test.App".Context.sockets = [
          "wayland"
          "!x11"
        ];
        files = [ ./fixtures/org.test.Ref ];
        writeMode = "merge";
      };
      configRepoPath = "/home/owner/cfg";
      bundleDir = "/root/bundles";
      lockRuntimes = true;
      uninstallUnused = true;
      update.auto.enable = true;
      restartOnFailure.enable = false;
    };

    systemd.services.flatlock.preStart = ''
      ${pkgs.flatpak}/bin/flatpak remote-add --system --if-not-exists \
        --no-gpg-verify local file:///etc/flatlock-test-repo
    '';

    environment.systemPackages = [
      pkgs.jq
      pkgs.util-linux
    ];
  };

  nodes.user = { lib, pkgs, ... }: {
    imports = [ homeManagerModule ];

    virtualisation.memorySize = 1536;
    environment.etc."flatlock-test-repo".source = "${testRepo}/repo";
    environment.etc."flatlock-test-repo.flatpakrepo".source = "${testRepo}/local.flatpakrepo";
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.alice = {
        imports = [ ../_modules/home-manager.nix ];
        home = {
          username = "alice";
          homeDirectory = "/home/alice";
          stateVersion = "25.11";
        };
        flatlock = {
          enable = true;
          defaultOrigin = "local";
          remotes = lib.mkForce {
            local = {
              location = "file://${testRepo}/local.flatpakrepo";
              extraArgs = [ "--no-gpg-verify" ];
            };
          };
          packages = [
            {
              appId = "org.test.User";
              pin = false;
            }
            {
              inherit flatpakref;
              pin = false;
            }
          ];
          overrides.settings."org.test.User".Environment.USER_TARGET = "1";
          configRepoPath = "/home/alice/cfg";
          lockFileRelativePath = "flatpak-user.lock";
          activation.mode = "background";
          update.auto.enable = true;
          restartOnFailure.enable = false;
        };
      };
    };
  };

  testScript = ''
    import json

    start_all()
    machine.wait_for_unit("multi-user.target")
    user.wait_for_unit("multi-user.target")

    commits = json.loads(machine.succeed("cat ${testRepo}/commits.json"))
    app_v1 = commits["app_v1"]
    app_v2 = commits["app_v2"]
    bundle_v1 = commits["bundle_v1"]
    bundle_v2 = commits["bundle_v2"]
    extension_v1 = commits["extension_v1"]
    runtime_v1 = commits["runtime_v1"]
    runtime_v2 = commits["runtime_v2"]
    extension_ref = "runtime/org.test.Extension/x86_64/stable"
    runtime_ref = "runtime/org.test.Platform/x86_64/stable"

    script = machine.succeed(
        "systemctl cat flatlock.service | grep ^ExecStart= | cut -d= -f2-"
    ).strip()
    manifest = machine.succeed(
        f"grep -oP 'FLATLOCK_MANIFEST:-\\K[^}}]+' {script} | head -n1"
    ).strip()
    update_script = machine.succeed(
        "systemctl cat flatlock-update.service | grep ^ExecStart= | cut -d= -f2-"
    ).strip()

    with subtest("system target installs every source type and both branches"):
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.App"
        ).strip() == app_v2
        machine.succeed("flatpak info --system --show-commit org.test.Ref//stable")
        machine.succeed("flatpak info --system --show-commit org.test.Branch/x86_64/stable")
        machine.succeed("flatpak info --system --show-commit org.test.Branch//beta")
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.Bundle//stable"
        ).strip() == bundle_v1
        assert machine.succeed(
            "flatpak info --system --show-origin org.test.Ref//stable"
        ).strip() == "local"
        assert machine.succeed(
            f"flatpak info --system --show-commit {extension_ref}"
        ).strip() == extension_v1
        assert machine.succeed(
            "flatpak remotes --system --columns=name,url | "
            "awk -F'\\t' '$1 == \"local\" {print $2}'"
        ).strip() == "file:///etc/flatlock-test-repo"
        state = json.loads(machine.succeed("cat /var/lib/flatlock/state.json"))
        assert state["remotes"]["local"]["url"] == "file:///etc/flatlock-test-repo"

    with subtest("status detects and reconciliation repairs drift"):
        machine.succeed("flatlock status --check")
        machine.succeed(
            "flatpak remote-modify --system --url=file:///missing local"
        )
        machine.fail("flatlock status --check")
        machine.succeed(f"FLATLOCK_MANIFEST={manifest} {script}")
        machine.succeed("flatlock status --check")

    with subtest("import prints applications remotes overrides and optional runtimes"):
        imported = machine.succeed("flatlock import")
        assert 'appId = "org.test.App"' in imported, imported
        assert '"local" = "file://${testRepo}/repo"' in imported, imported
        assert '"org.test.App" = {' in imported, imported
        assert "runtimes = [" not in imported, imported
        with_runtimes = machine.succeed("flatlock import --runtimes")
        assert 'id = "org.test.Extension"' in with_runtimes, with_runtimes

    with subtest("declared runtime extensions are removed and restored exactly"):
        machine.succeed(
            f"jq '.runtimePackages = []' {manifest} > /root/m-no-runtime-package.json"
        )
        machine.succeed(
            f"FLATLOCK_MANIFEST=/root/m-no-runtime-package.json {script}"
        )
        machine.fail(f"flatpak info --system --show-commit {extension_ref}")
        machine.succeed(f"FLATLOCK_MANIFEST={manifest} {script}")
        assert machine.succeed(
            f"flatpak info --system --show-commit {extension_ref}"
        ).strip() == extension_v1

    with subtest("declared application origin drift is repaired"):
        machine.succeed(
            "jq '(.apps[] | select(.ref == \"org.test.App\").origin) = \"alternate\"' "
            f"{manifest} > /root/m-origin.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-origin.json {script}")
        assert machine.succeed(
            "flatpak info --system --show-origin org.test.App"
        ).strip() == "alternate"
        machine.succeed(f"FLATLOCK_MANIFEST={manifest} {script}")
        assert machine.succeed(
            "flatpak info --system --show-origin org.test.App"
        ).strip() == "local"

    with subtest("override files load and merge declaratively"):
        app_override = machine.succeed(
            "cat /var/lib/flatpak/overrides/org.test.App"
        )
        ref_override = machine.succeed(
            "cat /var/lib/flatpak/overrides/org.test.Ref"
        )
        assert "sockets=wayland;!x11" in app_override, app_override
        assert "FROM_FILE=1" in ref_override, ref_override
        machine.succeed(
            "printf '\\n[External]\\nKEEP=1\\n' >> "
            "/var/lib/flatpak/overrides/org.test.App"
        )
        machine.succeed(
            f"jq '.overrides.settings[\"org.test.App\"].Context.sockets = [\"x11\"]' "
            f"{manifest} > /root/m-merge.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-merge.json {script}")
        merged = machine.succeed("cat /var/lib/flatpak/overrides/org.test.App")
        assert "sockets=x11" in merged, merged
        assert "KEEP=1" in merged, merged

        machine.succeed(
            "jq '.overrides.writeMode = \"replace\"' /root/m-merge.json "
            "> /root/m-replace.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-replace.json {script}")
        replaced = machine.succeed("cat /var/lib/flatpak/overrides/org.test.App")
        assert "KEEP=1" not in replaced, replaced

        machine.succeed("touch /var/lib/flatpak/overrides/org.test.Stale")
        machine.succeed(
            "jq 'del(.overrides.settings[\"org.test.Ref\"]) | "
            ".overrides.pruneRemoved = true' /root/m-replace.json "
            "> /root/m-safe-prune.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-safe-prune.json {script}")
        machine.fail("test -e /var/lib/flatpak/overrides/org.test.Ref")
        machine.succeed("test -e /var/lib/flatpak/overrides/org.test.Stale")
        machine.succeed(
            "jq '.overrides.pruneAll = true' /root/m-safe-prune.json "
            "> /root/m-prune.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-prune.json {script}")
        machine.fail("test -e /var/lib/flatpak/overrides/org.test.Stale")

    with subtest("pins use branch qualified masks"):
        machine.succeed(
            f"jq --arg app \"{app_v1}\" --arg branch \"{commits['branch_stable']}\" "
            "'(.apps[] | select(.ref == \"org.test.App\").commit) = $app | "
            "(.apps[] | select(.ref == \"org.test.Branch/x86_64/stable\").commit) = $branch' "
            f"/root/m-prune.json > /root/m-pin.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-pin.json {script}")
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.App"
        ).strip() == app_v1
        masks = [
            mask.strip()
            for mask in machine.succeed("flatpak mask --system").splitlines()
        ]
        assert "org.test.App" in masks, masks
        assert "org.test.Branch/x86_64/stable" in masks, masks
        assert "org.test.Branch//beta" not in masks, masks

    with subtest("failed reconciliation restores the complete mask set"):
        before = set(machine.succeed("flatpak mask --system").splitlines())
        state_before = machine.succeed(
            "sha256sum /var/lib/flatlock/state.json"
        ).split()[0]
        machine.succeed(
            "jq '(.apps[] | select(.ref == \"org.test.App\").commit) = "
            "\"0000000000000000000000000000000000000000000000000000000000000000\"' "
            "/root/m-pin.json > /root/m-fail.json"
        )
        machine.fail(f"FLATLOCK_MANIFEST=/root/m-fail.json {script}")
        after = set(machine.succeed("flatpak mask --system").splitlines())
        state_after = machine.succeed(
            "sha256sum /var/lib/flatlock/state.json"
        ).split()[0]
        assert before == after, (before, after)
        assert state_before == state_after

    with subtest("versioned lock includes apps and typed runtime pins"):
        machine.succeed("flatlock lock")
        lock = json.loads(
            machine.succeed("cat /home/owner/cfg/hosts/machine/flatpak.lock")
        )
        assert lock["version"] == 1, lock
        assert lock["apps"]["org.test.App"] == app_v1, lock
        assert "org.test.Branch/x86_64/stable" in lock["apps"], lock
        assert lock["runtimes"][extension_ref] == extension_v1, lock
        assert lock["runtimes"][runtime_ref] == runtime_v2, lock
        assert machine.succeed(
            "stat -c %U /home/owner/cfg/hosts/machine/flatpak.lock"
        ).strip() == "owner"
        machine.succeed("flatlock status | grep org.test.App")

        machine.succeed(
            "systemd-run --no-block --unit=flatlock-lock-holder --property=Type=oneshot "
            "/bin/sh -c 'flock /run/lock/flatlock-system.lock -c "
            "\"/run/current-system/sw/bin/touch /tmp/flatlock-lock-held; "
            "/run/current-system/sw/bin/sleep 2\"'"
        )
        machine.wait_until_succeeds("test -e /tmp/flatlock-lock-held")
        started = int(machine.succeed("date +%s").strip())
        machine.succeed("flatlock lock")
        elapsed = int(machine.succeed("date +%s").strip()) - started
        assert elapsed >= 1, elapsed

    with subtest("failed update restores application and runtime masks"):
        machine.succeed("flatpak remote-delete --system --force local")
        machine.fail("flatlock update org.test.App")
        masks = [
            mask.strip()
            for mask in machine.succeed("flatpak mask --system").splitlines()
        ]
        assert "org.test.App" in masks, masks
        assert runtime_ref in masks, masks
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-pin.json {script}")

    with subtest("missing pinned app cannot erase its lock"):
        before = machine.succeed(
            "sha256sum /home/owner/cfg/hosts/machine/flatpak.lock"
        ).split()[0]
        machine.succeed("flatpak mask --system --remove org.test.App")
        machine.succeed("flatpak uninstall --system --noninteractive org.test.App")
        machine.fail("flatlock lock")
        after = machine.succeed(
            "sha256sum /home/owner/cfg/hosts/machine/flatpak.lock"
        ).split()[0]
        assert before == after
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-pin.json {script}")

    with subtest("successful update rewrites locks and masks atomically"):
        machine.succeed("flatlock update org.test.App")
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.App"
        ).strip() == app_v2
        lock = json.loads(
            machine.succeed("cat /home/owner/cfg/hosts/machine/flatpak.lock")
        )
        assert lock["apps"]["org.test.App"] == app_v2, lock
        assert "org.test.App" in [
            mask.strip()
            for mask in machine.succeed("flatpak mask --system").splitlines()
        ]

    with subtest("bundle archive exports and prunes typed lock entries"):
        machine.succeed("flatlock bundle")
        machine.succeed(f"test -f /root/bundles/org.test.App-{app_v2}.flatpak")
        machine.succeed("touch /root/bundles/org.test.Stale-deadbeef.flatpak")
        machine.succeed("flatlock bundle prune")
        machine.fail("test -e /root/bundles/org.test.Stale-deadbeef.flatpak")

    with subtest("changed file URL bundle content reinstalls the new commit"):
        machine.succeed("cp ${testRepo}/bundle-v1.flatpak /root/current.flatpak")
        machine.succeed(
            "jq --arg source 'file:///root/current.flatpak' "
            "'(.apps[] | select(.id == \"org.test.Bundle\").source.path) = $source' "
            "/root/m-pin.json > /root/m-bundle.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-bundle.json {script}")
        machine.succeed("cp ${testRepo}/bundle-v2.flatpak /root/current.flatpak")
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-bundle.json {script}")
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.Bundle//stable"
        ).strip() == bundle_v2

    with subtest("runtime pins survive automatic application updates"):
        machine.succeed(
            f"jq --arg ref '{runtime_ref}' --arg commit '{runtime_v1}' "
            "'.runtimes = [{ref: $ref, commit: $commit}]' "
            "/root/m-bundle.json > /root/m-runtime.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-runtime.json {script}")
        assert machine.succeed(
            f"flatpak info --system --show-commit {runtime_ref}"
        ).strip() == runtime_v1
        updater = machine.succeed(f"cat {update_script}")
        assert "/bin/flatlock update" in updater, updater
        assert "flatpak --system update" not in updater, updater
        machine.succeed(update_script)
        assert machine.succeed(
            f"flatpak info --system --show-commit {runtime_ref}"
        ).strip() == runtime_v1

    with subtest("manual runtime update advances runtime pins"):
        machine.succeed("flatlock update --runtimes org.test.App")
        assert machine.succeed(
            f"flatpak info --system --show-commit {runtime_ref}"
        ).strip() == runtime_v2
        lock = json.loads(
            machine.succeed("cat /home/owner/cfg/hosts/machine/flatpak.lock")
        )
        assert lock["runtimes"][runtime_ref] == runtime_v2, lock
        masks = {
            mask.strip()
            for mask in machine.succeed("flatpak mask --system").splitlines()
        }
        assert runtime_ref in masks, masks

    with subtest("unmanaged cleanup removes only undeclared full refs"):
        machine.succeed(
            "jq '.uninstallUnmanaged = true | "
            ".apps |= map(select(.ref != \"org.test.Branch//beta\"))' "
            "/root/m-runtime.json > /root/m-one-branch.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-one-branch.json {script}")
        machine.succeed("flatpak info --system org.test.Branch/x86_64/stable --show-commit")
        machine.fail("flatpak info --system org.test.Branch//beta --show-commit")
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-runtime.json {script}")

    with subtest("empty CLI never performs a blanket update"):
        machine.succeed(
            "flatpak install --system --noninteractive local org.test.User"
        )
        before = machine.succeed(
            "flatpak info --system --show-commit org.test.User"
        ).strip()
        output = machine.succeed("${emptyCli}/bin/flatlock update")
        assert "no declared applications" in output, output
        after = machine.succeed(
            "flatpak info --system --show-commit org.test.User"
        ).strip()
        assert before == after
        machine.succeed(
            "flatpak uninstall --system --noninteractive org.test.User"
        )

    with subtest("remote drift is repaired from recorded state"):
        machine.succeed(
            "flatpak remote-modify --system --url=file:///missing local"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-runtime.json {script}")
        url = machine.succeed(
            "flatpak remotes --system --columns=name,url | awk -F'\\t' '$1 == \"local\" {print $2}'"
        ).strip()
        assert url == "file://${testRepo}/repo", url

    with subtest("in-use removed remote remains tracked for a later retry"):
        machine.succeed(
            "jq '.remotes = {} | .apps |= map(select(.id != \"org.test.Ref\"))' "
            "/root/m-runtime.json > /root/m-no-remote.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-no-remote.json {script}")
        state = json.loads(machine.succeed("cat /var/lib/flatlock/state.json"))
        assert "local" in state["remotes"], state
        machine.succeed("flatpak remotes --system --columns=name | grep -Fx local")

    with subtest("removing declarations cleans apps runtimes remotes and overrides"):
        machine.succeed(
            "jq '.apps = [] | .runtimePackages = [] | .runtimes = [] | "
            ".overrides.settings = {}' "
            "/root/m-no-remote.json > /root/m-empty.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-empty.json {script}")
        assert machine.succeed(
            "flatpak list --system --app --columns=application"
        ).strip() == ""
        machine.fail("test -e /var/lib/flatpak/overrides/org.test.App")
        machine.fail(
            "flatpak remotes --system --columns=name | grep -Fx local"
        )
        machine.fail(
            "flatpak list --system --runtime --columns=application | grep -Fx org.test.Platform"
        )

    with subtest("uninstallUnmanaged removes manually installed state"):
        machine.succeed(
            "flatpak remote-add --system --no-gpg-verify local file://${testRepo}/repo"
        )
        machine.succeed(
            "flatpak install --system --noninteractive local org.test.App"
        )
        machine.succeed(
            "jq '.uninstallUnmanaged = true' /root/m-empty.json "
            "> /root/m-unmanaged.json"
        )
        machine.succeed(f"FLATLOCK_MANIFEST=/root/m-unmanaged.json {script}")
        machine.fail("flatpak info --system --show-commit org.test.App")
        machine.fail(
            "flatpak remotes --system --columns=name | grep -Fx local"
        )

    with subtest("baked manifest reconverges after complete drift"):
        machine.succeed("systemctl start flatlock.service")
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.App"
        ).strip() == app_v2
        assert machine.succeed(
            "flatpak info --system --show-commit org.test.Bundle//stable"
        ).strip() == bundle_v1

    with subtest("Home Manager target manages an independent user installation"):
        user.succeed("loginctl enable-linger alice")
        user.succeed("systemctl start user@1000.service")
        user.wait_for_unit("user@1000.service")
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
            "systemctl --user daemon-reload"
        )
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
            "systemctl --user is-enabled flatlock.timer"
        )
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
            "systemctl --user start flatlock.timer"
        )
        user.wait_until_succeeds(
            "runuser -u alice -- env HOME=/home/alice "
            "/etc/profiles/per-user/alice/bin/flatpak --user "
            "info --show-commit org.test.User"
        )
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
            "systemctl --user start flatlock-update.service"
        )
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice "
            "/etc/profiles/per-user/alice/bin/flatpak --user "
            "info --show-commit org.test.User"
        )
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice "
            "/etc/profiles/per-user/alice/bin/flatpak --user "
            "info --show-commit org.test.Ref//stable"
        )
        override = user.succeed(
            "cat /home/alice/.local/share/flatpak/overrides/org.test.User"
        )
        assert "USER_TARGET=1" in override, override
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
            "/etc/profiles/per-user/alice/bin/flatlock lock"
        )
        user.succeed(
            "systemd-run --no-block --unit=flatlock-user-lock-holder "
            "--property=Type=oneshot --property=User=alice /bin/sh -c "
            "'flock /home/alice/.local/state/flatlock/mutation.lock -c "
            "\"/run/current-system/sw/bin/touch /tmp/flatlock-user-lock-held; "
            "/run/current-system/sw/bin/sleep 2\"'"
        )
        user.wait_until_succeeds("test -e /tmp/flatlock-user-lock-held")
        started = int(user.succeed("date +%s").strip())
        user.succeed(
            "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
            "/etc/profiles/per-user/alice/bin/flatlock lock"
        )
        elapsed = int(user.succeed("date +%s").strip()) - started
        assert elapsed >= 1, elapsed
        user_lock = json.loads(
            user.succeed("cat /home/alice/cfg/flatpak-user.lock")
        )
        assert user_lock["version"] == 1, user_lock
        assert "org.test.User" in user_lock["apps"], user_lock
  '';
}
