import configparser
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

from runtime import (
    FlatlockError,
    active_commit,
    atomic_write_json,
    command,
    ensure_directory,
    ensure_regular_or_missing,
    load_json,
    mask_add,
    mask_remove,
    mutation_guard,
    open_regular,
    output,
    safe_child,
    scope_paths,
    validate_lock,
)


def parse_deployed_ref(deployed_ref, kind=None):
    fields = deployed_ref.split("/")
    if len(fields) == 3 and kind in ("app", "runtime"):
        fields.insert(0, kind)
    if len(fields) != 4 or fields[0] not in ("app", "runtime"):
        raise FlatlockError(f"unexpected deployed ref: {deployed_ref}")
    return tuple(fields)


def build_bundle_command(repository, destination, deployed_ref):
    kind, name, arch, branch = parse_deployed_ref(deployed_ref)
    args = ["flatpak", "build-bundle", f"--arch={arch}"]
    if kind == "runtime":
        args.append("--runtime")
    args.extend([str(repository), str(destination), name, branch])
    return args


def nix_string(value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("${", "\\${")
    escaped = escaped.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return f'"{escaped}"'


def parse_override(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        handle = open_regular(path)
    except FileNotFoundError:
        return {}
    with handle:
        parser.read_file(handle)
    return {section: dict(parser.items(section)) for section in parser.sections()}


def normalize_override_settings(settings):
    return {
        section: {
            key: ";".join(value) if isinstance(value, list) else str(value)
            for key, value in values.items()
        }
        for section, values in settings.items()
    }


class FlatlockCli:
    def __init__(self, config):
        self.config = config
        self.installation = config["installation"]
        self.scope = f"--{self.installation}"
        self.declared_apps = config["declaredApps"]
        self.declared_runtimes = config.get("declaredRuntimes", [])
        self.declared = [*self.declared_apps, *self.declared_runtimes]
        self.pin_requested_apps = set(config["pinRequestedApps"])
        self.pin_requested_runtimes = set(config.get("pinRequestedRuntimes", []))
        self.pin_requested = self.pin_requested_apps | self.pin_requested_runtimes
        self.bundles = set(config["bundleApps"])
        self.declared_remotes = set(config.get("declaredRemotes", []))
        self.declared_remote_details = config.get("declaredRemoteDetails", {})
        self.expected_origins = config.get("expectedOrigins", {})
        self.override_settings = config.get("overrideSettings", {})
        self.override_write_mode = config.get("overrideWriteMode", "replace")
        self.uninstall_unmanaged = config.get("uninstallUnmanaged", False)
        self.lock_runtimes = config["lockRuntimes"]
        self.bundle_dir = config["bundleDir"]
        repository = config["configRepoPath"]
        self.lock_path = (
            None
            if repository is None
            else Path(repository) / config["lockFileRelativePath"]
        )

    def require_lock_path(self):
        if self.lock_path is None:
            raise FlatlockError("configRepoPath is unset")
        return self.lock_path

    def read_lock(self, required=False):
        path = self.require_lock_path()
        value = load_json(path, validate=validate_lock, missing=None, empty={})
        if value is None:
            if required:
                raise FlatlockError(f"no lock file at {path}")
            return {}
        return value

    def lock_maps(self, value):
        if "version" in value:
            return value.get("apps", {}), value.get("runtimes", {})
        return value, {}

    def all_lock_entries(self):
        apps, runtimes = self.lock_maps(self.read_lock(required=True))
        return {**apps, **runtimes}

    def current_remotes(self):
        value = output(self.scope, "remotes", "--columns=name,url") or ""
        return {
            fields[0]: fields[1]
            for line in value.splitlines()
            if len(fields := line.split("\t", 1)) == 2
        }

    def installed_full_refs(self, kind):
        value = output(self.scope, "list", f"--{kind}", "--columns=ref") or ""
        return {
            "/".join(parse_deployed_ref(ref, kind)) for ref in value.splitlines() if ref
        }

    def state(self):
        paths = scope_paths(self.installation)
        value = load_json(paths.state_dir / "state.json", missing={})
        if not isinstance(value, dict):
            raise FlatlockError("state file must contain a JSON object")
        return value, paths

    def override_drift(self, paths):
        issues = []
        for app_id, settings in self.override_settings.items():
            expected = normalize_override_settings(settings)
            active = parse_override(paths.override_dir / app_id)
            if self.override_write_mode == "replace":
                if active != expected:
                    issues.append(f"override differs: {app_id}")
                continue
            for section, values in expected.items():
                for key, value in values.items():
                    if active.get(section, {}).get(key) != value:
                        issues.append(f"override differs: {app_id} [{section}] {key}")
        return issues

    def drift(self, lock):
        issues = []
        apps, runtimes = self.lock_maps(lock)
        active = {ref: active_commit(self.scope, ref) for ref in self.declared}

        for ref in self.declared:
            if active[ref] is None:
                issues.append(f"missing declared ref: {ref}")

        for ref, commit in {**apps, **runtimes}.items():
            deployed = active.get(ref)
            if deployed is None and ref not in self.declared:
                deployed = active_commit(self.scope, ref)
            if deployed is not None and deployed != commit:
                issues.append(f"commit differs: {ref}")

        for ref, origin in self.expected_origins.items():
            if active.get(ref) is None:
                continue
            deployed_origin = output(self.scope, "info", ref, "--show-origin")
            if deployed_origin != origin:
                issues.append(f"origin differs: {ref}")

        state, paths = self.state()
        state_apps = state.get("apps", {})
        state_runtimes = state.get("runtimes", {})
        if not isinstance(state_apps, dict) or not isinstance(state_runtimes, dict):
            issues.append("managed state uses an invalid ref collection")
            state_apps = {}
            state_runtimes = {}
        for ref in self.declared_apps:
            if ref not in state_apps:
                issues.append(f"application is not recorded as managed: {ref}")
        for ref in self.declared_runtimes:
            if ref not in state_runtimes:
                issues.append(f"runtime is not recorded as managed: {ref}")

        remotes = self.current_remotes()
        state_remotes = state.get("remotes", {})
        if not isinstance(state_remotes, dict):
            issues.append("managed state uses an invalid remote collection")
            state_remotes = {}
        for name in self.declared_remotes:
            if name not in remotes:
                issues.append(f"missing declared remote: {name}")
                continue
            recorded = state_remotes.get(name, {})
            if not isinstance(recorded, dict):
                issues.append(f"remote is not recorded as managed: {name}")
                continue
            recorded_url = recorded.get("url")
            if recorded_url is not None and remotes[name] != recorded_url:
                issues.append(f"remote URL differs: {name}")
            details = self.declared_remote_details.get(name)
            if details is not None:
                identity = hashlib.sha256(
                    json.dumps(details, sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()
                if recorded.get("identity") != identity:
                    issues.append(f"remote configuration differs: {name}")

        issues.extend(self.override_drift(paths))

        if self.uninstall_unmanaged:
            desired_apps = {
                deployed
                for ref in self.declared_apps
                if (deployed := output(self.scope, "info", ref, "--show-ref"))
            }
            for ref in self.installed_full_refs("app") - desired_apps:
                issues.append(f"unmanaged application: {ref}")
            managed_remotes = self.declared_remotes | set(state_remotes)
            for name in set(remotes) - managed_remotes:
                issues.append(f"unmanaged remote: {name}")

        return list(dict.fromkeys(issues))

    def status(self, check=False):
        lock = self.read_lock() if self.lock_path is not None else {}
        apps, runtimes = self.lock_maps(lock)
        print(f"{'APP':52} {'ACTIVE':14} {'LOCKED':14}")
        for ref in self.declared_apps:
            active = active_commit(self.scope, ref) or "absent"
            locked = apps.get(ref, "-")
            print(f"{ref:52} {active[:12]:14} {locked[:12]:14}")
        runtime_refs = list(dict.fromkeys([*self.declared_runtimes, *runtimes]))
        if runtime_refs:
            print(f"\n{'RUNTIME':52} {'ACTIVE':14} {'LOCKED':14}")
            for ref in runtime_refs:
                active = active_commit(self.scope, ref) or "absent"
                locked = runtimes.get(ref, "-")
                print(f"{ref:52} {active[:12]:14} {locked[:12]:14}")
        if not check:
            return True
        issues = self.drift(lock)
        if issues:
            print("\nDRIFT")
            for issue in issues:
                print(f"  {issue}")
            return False
        print("\nflatlock: state matches declaration")
        return True

    def installed_rows(self, kind):
        value = (
            output(
                self.scope,
                "list",
                f"--{kind}",
                "--columns=ref,origin",
            )
            or ""
        )
        rows = []
        for line in value.splitlines():
            fields = line.split("\t", 1)
            deployed = parse_deployed_ref(fields[0], kind)
            origin = (
                fields[1] if len(fields) == 2 and fields[1] not in ("", "-") else None
            )
            rows.append((*deployed, origin))
        return sorted(rows)

    def imported_overrides(self):
        paths = scope_paths(self.installation)
        directory = paths.override_dir
        if directory.is_symlink():
            raise FlatlockError(f"unsafe directory: {directory}")
        if not directory.exists():
            return {}
        if not directory.is_dir():
            raise FlatlockError(f"unsafe directory: {directory}")
        return {
            path.name: parse_override(path)
            for path in sorted(directory.iterdir())
            if path.is_file() and not path.is_symlink()
        }

    def print_import(self, include_runtimes=False):
        remotes = self.current_remotes()
        apps = self.installed_rows("app")
        runtimes = self.installed_rows("runtime") if include_runtimes else []
        overrides = self.imported_overrides()

        print("flatlock = {")
        if remotes:
            print("  remotes = {")
            for name, location in sorted(remotes.items()):
                if location:
                    print(f"    {nix_string(name)} = {nix_string(location)};")
            print("  };")
        if apps:
            print("  packages = [")
            for _, app_id, arch, branch, origin in apps:
                print("    {")
                print(f"      appId = {nix_string(app_id)};")
                if origin is not None:
                    print(f"      origin = {nix_string(origin)};")
                print(f"      arch = {nix_string(arch)};")
                print(f"      branch = {nix_string(branch)};")
                print("    }")
            print("  ];")
        if runtimes:
            print("  runtimes = [")
            for _, runtime_id, arch, branch, origin in runtimes:
                print("    {")
                print(f"      id = {nix_string(runtime_id)};")
                if origin is not None:
                    print(f"      origin = {nix_string(origin)};")
                print(f"      arch = {nix_string(arch)};")
                print(f"      branch = {nix_string(branch)};")
                print("    }")
            print("  ];")
        if overrides:
            print("  overrides.settings = {")
            for app_id, sections in sorted(overrides.items()):
                print(f"    {nix_string(app_id)} = {{")
                for section, values in sorted(sections.items()):
                    print(f"      {nix_string(section)} = {{")
                    for key, value in sorted(values.items()):
                        print(f"        {nix_string(key)} = {nix_string(value)};")
                    print("      };")
                print("    };")
            print("  };")
        print("};")

    def collect_lock(self):
        apps = {}
        for ref in self.declared_apps:
            commit = active_commit(self.scope, ref)
            if commit is None:
                if ref in self.pin_requested_apps:
                    raise FlatlockError(f"pinned application is not installed: {ref}")
                print(
                    f"flatlock: skipping absent unpinned application {ref}",
                    file=sys.stderr,
                )
                continue
            apps[ref] = commit

        runtimes = {}
        for ref in self.declared_runtimes:
            commit = active_commit(self.scope, ref)
            if commit is None:
                if ref in self.pin_requested_runtimes:
                    raise FlatlockError(f"pinned runtime is not installed: {ref}")
                print(
                    f"flatlock: skipping absent unpinned runtime {ref}",
                    file=sys.stderr,
                )
                continue
            runtimes[ref] = commit
        if self.lock_runtimes:
            value = output(self.scope, "list", "--runtime", "--columns=ref") or ""
            for listed_ref in value.splitlines():
                ref = (
                    listed_ref
                    if listed_ref.startswith("runtime/")
                    else f"runtime/{listed_ref}"
                )
                commit = active_commit(self.scope, ref)
                if commit is None:
                    raise FlatlockError(f"cannot resolve runtime commit: {ref}")
                runtimes[ref] = commit
        return {"version": 1, "apps": apps, "runtimes": runtimes}

    def write_lock(self):
        path = self.require_lock_path()
        value = self.collect_lock()
        for ref in self.pin_requested:
            if active_commit(self.scope, ref) is not None:
                mask_add(self.scope, ref)
        if self.lock_runtimes:
            for ref in value["runtimes"]:
                mask_add(self.scope, ref)
        atomic_write_json(path, value)
        print(f"flatlock: wrote {path}")

    def lock(self):
        with mutation_guard(self.installation):
            self.write_lock()

    def update_one(self, ref, with_dependencies=False):
        origin = output(self.scope, "info", ref, "--show-origin")
        if origin is None:
            raise FlatlockError(f"ref is not installed: {ref}")
        latest = output(self.scope, "remote-info", origin, ref, "--show-commit")
        if not latest:
            raise FlatlockError(
                f"cannot resolve the latest commit for {ref} from {origin}"
            )
        dependency_args = (
            ["--no-deps", "--no-related"]
            if self.lock_runtimes and not with_dependencies
            else []
        )
        result = subprocess.run(
            [
                "flatpak",
                self.scope,
                "update",
                "--noninteractive",
                *dependency_args,
                f"--commit={latest}",
                ref,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={**os.environ, "LC_ALL": "C"},
        )
        if result.stdout:
            print(result.stdout, end="")
        if (
            result.returncode != 0
            or "Unable to update" in result.stdout
            or "Error:" in result.stdout
        ):
            raise FlatlockError(f"flatpak update failed for {ref}")
        if active_commit(self.scope, ref) != latest:
            command(
                self.scope,
                "install",
                "--noninteractive",
                "--reinstall",
                *dependency_args,
                origin,
                ref,
            )
        if active_commit(self.scope, ref) != latest:
            raise FlatlockError(f"flatpak did not deploy the latest commit for {ref}")

    def installed_runtime_refs(self):
        value = output(self.scope, "list", "--runtime", "--columns=ref") or ""
        return sorted(
            {
                ref if ref.startswith("runtime/") else f"runtime/{ref}"
                for ref in value.splitlines()
                if ref
            }
        )

    def update(self, targets, update_runtimes=False):
        if update_runtimes and not self.lock_runtimes:
            raise FlatlockError("--runtimes requires lockRuntimes")
        targets = (
            list(targets)
            if targets
            else [ref for ref in self.declared if ref not in self.bundles]
        )
        if not targets and not update_runtimes:
            print("flatlock: no declared applications to update")
            return
        for ref in targets:
            if ref not in self.declared:
                raise FlatlockError(f"ref is not declared: {ref}")
            if ref in self.bundles:
                raise FlatlockError(
                    f"bundle applications cannot be updated from a remote: {ref}"
                )

        with mutation_guard(self.installation):
            for ref in targets:
                mask_remove(self.scope, ref)
            if self.lock_runtimes and self.lock_path is not None:
                lock = self.read_lock()
                _, runtimes = self.lock_maps(lock)
                for ref in runtimes:
                    mask_remove(self.scope, ref)
            for ref in targets:
                self.update_one(ref, with_dependencies=update_runtimes)
            if update_runtimes:
                for ref in self.installed_runtime_refs():
                    mask_remove(self.scope, ref)
                    self.update_one(ref, with_dependencies=True)
            self.write_lock()
        print("flatlock: lock and masks updated")

    def flatpak_repo(self):
        if self.installation == "system":
            return Path("/var/lib/flatpak/repo")
        data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        return data_home / "flatpak/repo"

    def bundle_ref(self, ref, commit, directory):
        if active_commit(self.scope, ref) != commit:
            print(
                f"flatlock: skipping {ref} because its active commit differs",
                file=sys.stderr,
            )
            return
        deployed_ref = output(self.scope, "info", ref, "--show-ref")
        if deployed_ref is None:
            raise FlatlockError(f"cannot resolve deployed ref: {ref}")
        destination = safe_child(directory, f"{ref.replace('/', '_')}-{commit}.flatpak")
        if destination.exists():
            return
        temporary = safe_child(directory, f".{destination.name}.tmp")
        temporary.unlink(missing_ok=True)
        repository = self.flatpak_repo()
        refs = subprocess.run(
            ["ostree", f"--repo={repository}", "refs"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.splitlines()
        created_ref = deployed_ref not in refs
        if created_ref:
            subprocess.run(
                [
                    "ostree",
                    f"--repo={repository}",
                    "refs",
                    f"--create={deployed_ref}",
                    commit,
                ],
                check=True,
            )
        try:
            subprocess.run(
                build_bundle_command(repository, temporary, deployed_ref), check=True
            )
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
            if created_ref:
                subprocess.run(
                    [
                        "ostree",
                        f"--repo={repository}",
                        "refs",
                        "--delete",
                        deployed_ref,
                    ],
                    check=False,
                )
        print(f"flatlock: bundled {ref}")

    def bundle(self, prune=False):
        if self.bundle_dir is None:
            raise FlatlockError("bundleDir is unset")
        with mutation_guard(self.installation):
            directory = ensure_directory(
                Path(os.path.expandvars(os.path.expanduser(self.bundle_dir)))
            )
            entries = self.all_lock_entries()
            expected = {
                f"{ref.replace('/', '_')}-{commit}.flatpak"
                for ref, commit in entries.items()
            }
            if prune:
                for path in directory.glob("*.flatpak"):
                    ensure_regular_or_missing(path)
                    if path.name not in expected:
                        path.unlink()
                        print(f"flatlock: pruned {path.name}")
                return
            for ref, commit in entries.items():
                self.bundle_ref(ref, commit, directory)


def usage():
    print(
        """usage: flatlock <command>

  status [--check] show commits and optionally fail when managed state has drifted
  import [--runtimes]
                   print declarations for installed state without changing it
  lock             record active commits and apply masks
  update [--runtimes] [app...]
                   update declared apps and optionally advance runtime pins
  bundle [prune]   archive locked refs or remove stale archives"""
    )


def main():
    if len(sys.argv) < 3:
        usage()
        raise SystemExit(1)
    config = load_json(Path(sys.argv[1]))
    cli = FlatlockCli(config)
    command_name = sys.argv[2]
    arguments = sys.argv[3:]
    if command_name == "status" and arguments in ([], ["--check"]):
        if not cli.status(check=arguments == ["--check"]):
            raise SystemExit(2)
    elif command_name == "import" and arguments in ([], ["--runtimes"]):
        cli.print_import(include_runtimes=arguments == ["--runtimes"])
    elif command_name == "lock" and not arguments:
        cli.lock()
    elif command_name == "update":
        update_runtimes = "--runtimes" in arguments
        if arguments.count("--runtimes") > 1:
            raise FlatlockError("--runtimes may only be specified once")
        cli.update(
            [argument for argument in arguments if argument != "--runtimes"],
            update_runtimes=update_runtimes,
        )
    elif command_name == "bundle" and arguments in ([], ["prune"]):
        cli.bundle(prune=arguments == ["prune"])
    elif command_name in ("-h", "--help", "help") and not arguments:
        usage()
    else:
        usage()
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except (FlatlockError, subprocess.CalledProcessError) as error:
        print(f"flatlock: {error}", file=sys.stderr)
        raise SystemExit(1) from error
