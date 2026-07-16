import hashlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


library = Path(os.environ["FLATLOCK_LIB"])


def load_module(name):
    path = library / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"flatlock_{name}", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


runtime = load_module("runtime")
reconciler = load_module("reconcile")
cli = load_module("cli")


class SourceIdentityTests(unittest.TestCase):
    def test_file_url_uses_file_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bundle with spaces.flatpak"
            path.write_bytes(b"bundle-v1")
            expected = hashlib.sha256(b"bundle-v1").hexdigest()

            identity = reconciler.source_identity(
                {"kind": "bundle", "path": path.as_uri()}
            )

            self.assertEqual(identity, f"bundle:{expected}")

    def test_non_file_url_remains_opaque(self):
        source = {"kind": "bundle", "path": "https://example.invalid/app.flatpak"}
        self.assertEqual(
            reconciler.source_identity(source),
            "bundle:https://example.invalid/app.flatpak",
        )


class RefTests(unittest.TestCase):
    def test_installed_refs_are_kind_qualified(self):
        with mock.patch.object(
            reconciler,
            "output",
            return_value="org.test.App/x86_64/stable\napp/org.test.Other/aarch64/beta",
        ):
            refs = reconciler.installed_app_refs("--system")

        self.assertEqual(
            refs,
            {
                "app/org.test.App/x86_64/stable",
                "app/org.test.Other/aarch64/beta",
            },
        )


class MaskTests(unittest.TestCase):
    def test_restore_masks_reverts_additions_and_removals(self):
        with (
            mock.patch.object(
                runtime,
                "current_masks",
                return_value={"org.test.New", "org.test.Shared"},
            ),
            mock.patch.object(runtime, "mask_remove") as remove,
            mock.patch.object(runtime, "mask_add") as add,
        ):
            runtime.restore_masks("--system", {"org.test.Old", "org.test.Shared"})

        remove.assert_called_once_with("--system", "org.test.New")
        add.assert_called_once_with("--system", "org.test.Old")


class AtomicWriteTests(unittest.TestCase):
    def test_root_writer_preserves_existing_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "flatpak.lock"
            path.write_text("old")
            metadata = path.stat()

            with (
                mock.patch.object(runtime.os, "geteuid", return_value=0),
                mock.patch.object(runtime.os, "fchown") as fchown,
            ):
                runtime.atomic_write_text(path, "new")

            self.assertEqual(path.read_text(), "new")
            fchown.assert_called_once()
            self.assertEqual(
                fchown.call_args.args[1:],
                (metadata.st_uid, metadata.st_gid),
            )


class OverrideTests(unittest.TestCase):
    def manifest(self, **values):
        config = {
            "settings": {},
            "writeMode": "merge",
            "pruneRemoved": False,
            "pruneAll": False,
        }
        config.update(values)
        return {"overrides": config}

    def prepare(self, directory):
        managed = directory / "org.test.Managed"
        managed.write_text("[Context]\nmanaged=1\n\n[External]\nKEEP=1\n")
        manual = directory / "org.test.Manual"
        manual.write_text("[External]\nKEEP=1\n")
        old = {
            "overrides": {
                "settings": {"org.test.Managed": {"Context": {"managed": "1"}}}
            }
        }
        return old, managed, manual

    def test_default_removal_preserves_external_values_and_manual_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            old, managed, manual = self.prepare(directory)

            reconciler.reconcile_overrides(old, self.manifest(), directory)

            self.assertEqual(managed.read_text(), "[External]\nKEEP=1\n")
            self.assertTrue(manual.exists())

    def test_prune_removed_deletes_only_previously_managed_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            old, managed, manual = self.prepare(directory)

            reconciler.reconcile_overrides(
                old, self.manifest(pruneRemoved=True), directory
            )

            self.assertFalse(managed.exists())
            self.assertTrue(manual.exists())

    def test_prune_all_deletes_every_undeclared_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            old, managed, manual = self.prepare(directory)

            reconciler.reconcile_overrides(old, self.manifest(pruneAll=True), directory)

            self.assertFalse(managed.exists())
            self.assertFalse(manual.exists())

    def test_symlink_override_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "target"
            target.write_text("external")
            (directory / "org.test.Managed").symlink_to(target)
            old = {
                "overrides": {
                    "settings": {"org.test.Managed": {"Context": {"managed": "1"}}}
                }
            }

            with self.assertRaises(runtime.FlatlockError):
                reconciler.reconcile_overrides(old, self.manifest(), directory)

            self.assertEqual(target.read_text(), "external")


class StateTests(unittest.TestCase):
    def test_version_one_list_state_is_migrated(self):
        self.assertEqual(
            reconciler.old_apps({"apps": ["org.test.App"]}),
            {"org.test.App": {}},
        )
        self.assertEqual(
            reconciler.old_remotes({"remotes": ["flathub"]}),
            {"flathub": {}},
        )
        self.assertEqual(
            reconciler.old_runtimes({"runtimes": ["runtime/org.test.Extension"]}),
            {"runtime/org.test.Extension": {}},
        )

    def test_symlink_state_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "target.json"
            target.write_text("{}")
            state = directory / "state.json"
            state.symlink_to(target)

            with self.assertRaises(runtime.FlatlockError):
                reconciler.load_state(state)

    def test_unsupported_state_version_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state.json"
            state.write_text('{"version": 99}')

            with self.assertRaisesRegex(runtime.FlatlockError, "unsupported version"):
                reconciler.load_state(state)

    def test_invalid_state_collection_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state.json"
            state.write_text('{"version": 2, "apps": "invalid"}')

            with self.assertRaisesRegex(runtime.FlatlockError, "state apps"):
                reconciler.load_state(state)


class RemoteAdoptionTests(unittest.TestCase):
    def test_existing_remote_is_adopted_without_replacement(self):
        manifest = {
            "apps": [],
            "runtimePackages": [],
            "runtimes": [],
            "remotes": {
                "local": {
                    "location": "https://example.invalid/repo.flatpakrepo",
                    "gpgImport": None,
                    "extraArgs": [],
                }
            },
            "overrides": {
                "settings": {},
                "writeMode": "replace",
                "pruneRemoved": False,
                "pruneAll": False,
            },
            "updateOnActivation": False,
            "uninstallUnmanaged": False,
            "uninstallUnused": False,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (
                mock.patch.object(
                    reconciler,
                    "remote_details",
                    return_value={"local": "https://existing.invalid/repo"},
                ),
                mock.patch.object(reconciler, "command") as command,
            ):
                reconciler.reconcile(
                    manifest,
                    "--system",
                    root / "state",
                    root / "overrides",
                )

            command.assert_not_called()
            state = runtime.load_json(root / "state/state.json")
            self.assertEqual(
                state["remotes"]["local"]["url"],
                "https://existing.invalid/repo",
            )


class CliImportTests(unittest.TestCase):
    def cli(self):
        return cli.FlatlockCli(
            {
                "installation": "system",
                "declaredApps": [],
                "declaredRuntimes": [],
                "pinRequestedApps": [],
                "pinRequestedRuntimes": [],
                "bundleApps": [],
                "lockRuntimes": False,
                "bundleDir": None,
                "configRepoPath": None,
                "lockFileRelativePath": "flatpak.lock",
            }
        )

    def test_import_renders_exact_refs_and_overrides(self):
        command = self.cli()
        with (
            mock.patch.object(
                command,
                "current_remotes",
                return_value={"local": "https://example.invalid/repo"},
            ),
            mock.patch.object(
                command,
                "installed_rows",
                side_effect=[
                    [("app", "org.test.App", "x86_64", "stable", "local")],
                    [
                        (
                            "runtime",
                            "org.test.Extension",
                            "x86_64",
                            "stable",
                            "local",
                        )
                    ],
                ],
            ),
            mock.patch.object(
                command,
                "imported_overrides",
                return_value={"org.test.App": {"Context": {"sockets": "wayland"}}},
            ),
            redirect_stdout(io.StringIO()) as output,
        ):
            command.print_import(include_runtimes=True)

        rendered = output.getvalue()
        self.assertIn('appId = "org.test.App";', rendered)
        self.assertIn('id = "org.test.Extension";', rendered)
        self.assertIn('"sockets" = "wayland";', rendered)

    def test_nix_strings_escape_interpolation(self):
        self.assertEqual(cli.nix_string('${HOME}/"file"'), '"\\${HOME}/\\"file\\""')


class SourceConvergenceTests(unittest.TestCase):
    def remote_app(self):
        return {
            "commit": None,
            "mask": "org.test.App",
            "origin": "declared",
            "ref": "org.test.App",
            "source": {"kind": "remote", "path": None},
        }

    def test_remote_origin_drift_forces_reinstall(self):
        deployed = "app/org.test.App/x86_64/stable"
        old = {
            "org.test.App": {"sourceIdentity": "remote"},
            "pins": set(),
        }
        with (
            mock.patch.object(reconciler, "installed", return_value=True),
            mock.patch.object(
                reconciler, "app_origin", side_effect=["unexpected", "declared"]
            ),
            mock.patch.object(reconciler, "output", return_value=deployed),
            mock.patch.object(reconciler, "command") as command,
        ):
            result = reconciler.reconcile_app(
                "--system", self.remote_app(), old, False, None
            )

        command.assert_called_once_with(
            "--system",
            "install",
            "--noninteractive",
            "--reinstall",
            "declared",
            "org.test.App",
        )
        self.assertEqual(result["origin"], "declared")

    def test_existing_unmanaged_bundle_is_reinstalled(self):
        app = {
            "commit": None,
            "mask": "org.test.Bundle//stable",
            "origin": "bundle-origin",
            "ref": "org.test.Bundle//stable",
            "source": {"kind": "bundle", "path": "/bundle.flatpak"},
        }
        deployed = "app/org.test.Bundle/x86_64/stable"
        with (
            mock.patch.object(reconciler, "installed", return_value=True),
            mock.patch.object(reconciler, "source_identity", return_value="bundle:x"),
            mock.patch.object(reconciler, "app_origin", return_value="bundle-origin"),
            mock.patch.object(reconciler, "output", return_value=deployed),
            mock.patch.object(reconciler, "command") as command,
        ):
            reconciler.reconcile_app("--system", app, {"pins": set()}, False, None)

        command.assert_called_once_with(
            "--system",
            "install",
            "--noninteractive",
            "--reinstall",
            "--bundle",
            "/bundle.flatpak",
        )


class BundleCommandTests(unittest.TestCase):
    def test_export_uses_deployed_architecture(self):
        command = cli.build_bundle_command(
            Path("/repo"),
            Path("/archive.flatpak"),
            "app/org.test.App/aarch64/stable",
        )

        self.assertEqual(
            command,
            [
                "flatpak",
                "build-bundle",
                "--arch=aarch64",
                "/repo",
                "/archive.flatpak",
                "org.test.App",
                "stable",
            ],
        )


class BundleFallbackTests(unittest.TestCase):
    def test_locked_update_falls_back_to_archive(self):
        ref = "org.test.App//stable"
        commit = "a" * 64
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / reconciler.bundle_name(ref, commit)
            archive.write_bytes(b"bundle")
            failed = SimpleNamespace(returncode=1, args=["flatpak", "update"])

            with (
                mock.patch.object(
                    reconciler, "command", side_effect=[failed, None]
                ) as command,
                mock.patch.object(reconciler, "active_commit", return_value=commit),
            ):
                reconciler.update_to_commit("--system", ref, commit, str(directory))

            command.assert_called_with(
                "--system",
                "install",
                "--noninteractive",
                "--reinstall",
                "--bundle",
                str(archive),
            )


class LockValidationTests(unittest.TestCase):
    def test_empty_lock_uses_the_requested_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "flatpak.lock"
            path.write_text("")

            value = runtime.load_json(
                path,
                validate=runtime.validate_lock,
                empty={},
            )

        self.assertEqual(value, {})

    def test_malformed_json_reports_a_flatlock_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "flatpak.lock"
            path.write_text("{")

            with self.assertRaises(runtime.FlatlockError):
                runtime.load_json(path, validate=runtime.validate_lock)

    def test_valid_versioned_lock_is_accepted(self):
        value = {
            "version": 1,
            "apps": {"org.test.App": "a" * 64},
            "runtimes": {},
        }
        self.assertIs(runtime.validate_lock(value), value)


if __name__ == "__main__":
    unittest.main()
