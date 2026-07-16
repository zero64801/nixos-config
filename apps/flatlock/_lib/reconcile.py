import configparser
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

from runtime import (
    FlatlockError,
    active_commit,
    atomic_write_json,
    atomic_write_text,
    command,
    ensure_directory,
    ensure_regular_or_missing,
    installed,
    load_json,
    mask_add,
    mask_remove,
    mutation_guard,
    open_regular,
    output,
    safe_child,
)


def local_source_path(value):
    parsed = urlparse(value)
    if parsed.scheme == "file":
        if parsed.netloc not in ("", "localhost"):
            return None
        return Path(unquote(parsed.path))
    if parsed.scheme != "":
        return None
    return Path(os.path.expandvars(os.path.expanduser(value)))


def source_identity(source):
    kind = source["kind"]
    path = source.get("path")
    if path is None:
        return kind
    source_path = local_source_path(path)
    if source_path is None or not source_path.is_file():
        return f"{kind}:{path}"
    digest = hashlib.sha256()
    with source_path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return f"{kind}:{digest.hexdigest()}"


def bundle_name(ref, commit):
    return f"{ref.replace('/', '_')}-{commit}.flatpak"


def update_to_commit(scope, ref, commit, bundle_dir):
    result = command(
        scope,
        "update",
        "--noninteractive",
        f"--commit={commit}",
        ref,
        check=False,
    )
    if result.returncode == 0 and active_commit(scope, ref) == commit:
        return
    error_code = result.returncode or 1
    if bundle_dir is None:
        raise subprocess.CalledProcessError(error_code, result.args)
    directory = ensure_directory(
        Path(os.path.expandvars(os.path.expanduser(bundle_dir)))
    )
    archive = safe_child(directory, bundle_name(ref, commit))
    if not archive.is_file():
        raise subprocess.CalledProcessError(error_code, result.args)
    command(
        scope, "install", "--noninteractive", "--reinstall", "--bundle", str(archive)
    )
    if active_commit(scope, ref) != commit:
        raise subprocess.CalledProcessError(1, result.args)


def load_state(path):
    state = load_json(path, missing={})
    if not isinstance(state, dict):
        raise FlatlockError("state file must contain a JSON object")
    version = state.get("version")
    if version not in (None, 1, 2, 3):
        raise FlatlockError("state file uses an unsupported version")
    for key in ("apps", "runtimes", "remotes"):
        value = state.get(key, {})
        valid_legacy = isinstance(value, list) and all(
            isinstance(item, str) for item in value
        )
        valid_current = isinstance(value, dict) and all(
            isinstance(name, str) and isinstance(details, dict)
            for name, details in value.items()
        )
        if not valid_legacy and not valid_current:
            raise FlatlockError(f"state {key} must contain named objects")
    for key in ("pins", "runtimePins", "runtimePackagePins"):
        value = state.get(key, [])
        if not isinstance(value, list) or not all(
            isinstance(item, str) for item in value
        ):
            raise FlatlockError(f"state {key} must contain strings")
    if not isinstance(state.get("overrides", {}), dict):
        raise FlatlockError("state overrides must contain a JSON object")
    return state


def old_apps(state):
    apps = state.get("apps", {})
    if isinstance(apps, list):
        return {ref: {} for ref in apps}
    return apps


def old_remotes(state):
    remotes = state.get("remotes", {})
    if isinstance(remotes, list):
        return {name: {} for name in remotes}
    return remotes


def old_runtimes(state):
    runtimes = state.get("runtimes", {})
    if isinstance(runtimes, list):
        return {ref: {} for ref in runtimes}
    return runtimes


def remote_details(scope):
    value = output(scope, "remotes", "--columns=name,url")
    if value is None or value == "":
        return {}
    return {
        fields[0]: fields[1]
        for line in value.splitlines()
        if len(fields := line.split("\t", 1)) == 2
    }


def remote_identity(remote):
    return hashlib.sha256(
        json.dumps(remote, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def add_remote(scope, name, remote):
    args = ["remote-add", "--if-not-exists"]
    if remote.get("gpgImport") is not None:
        args.append(f"--gpg-import={remote['gpgImport']}")
    args.extend(remote.get("extraArgs", []))
    args.extend([name, remote["location"]])
    command(scope, *args)


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


def rendered_value(value):
    return ";".join(value) if isinstance(value, list) else str(value)


def write_override(path, sections):
    if not sections:
        ensure_regular_or_missing(path)
        path.unlink(missing_ok=True)
        return
    lines = []
    for index, section in enumerate(sorted(sections)):
        if index:
            lines.append("")
        lines.append(f"[{section}]")
        for key in sorted(sections[section]):
            lines.append(f"{key}={rendered_value(sections[section][key])}")
    atomic_write_text(path, "\n".join(lines) + "\n")


def remove_managed_values(active, managed):
    for section, values in managed.items():
        if section not in active:
            continue
        for key in values:
            active[section].pop(key, None)
        if not active[section]:
            active.pop(section)


def apply_managed_values(active, managed):
    for section, values in managed.items():
        active.setdefault(section, {})
        for key, value in values.items():
            active[section][key] = value


def reconcile_overrides(old, manifest, directory):
    config = manifest["overrides"]
    new_settings = config["settings"]
    old_overrides = old.get("overrides", {})
    old_settings = old_overrides.get("settings", old_overrides)
    ensure_directory(directory)
    app_ids = set(old_settings) | set(new_settings)

    for app_id in app_ids:
        path = safe_child(directory, app_id)
        active = parse_override(path) if config["writeMode"] == "merge" else {}
        remove_managed_values(active, old_settings.get(app_id, {}))
        apply_managed_values(active, new_settings.get(app_id, {}))
        write_override(path, active)

    if config["pruneRemoved"]:
        for app_id in set(old_settings) - set(new_settings):
            safe_child(directory, app_id).unlink(missing_ok=True)

    if config["pruneAll"]:
        for path in directory.iterdir():
            ensure_regular_or_missing(path)
            if path.name not in new_settings:
                path.unlink()


def app_origin(scope, ref, fallback):
    return output(scope, "info", ref, "--show-origin") or fallback


def reconcile_app(scope, app, old, update_on_activation, bundle_dir):
    ref = app["ref"]
    source = app["source"]
    identity = source_identity(source)
    previously_managed = ref in old
    previous = old.get(ref, {})
    changed = previously_managed and previous.get("sourceIdentity") != identity

    if app["commit"] is not None or ref in old.get("pins", []):
        mask_remove(scope, app["mask"])

    exists = installed(scope, ref)
    source_unverified = (
        exists and not previously_managed and source["kind"] in ("bundle", "flatpakref")
    )
    if source["kind"] == "bundle":
        if not exists or changed or source_unverified:
            args = ["install", "--noninteractive"]
            if exists:
                args.append("--reinstall")
            args.extend(["--bundle", source["path"]])
            command(scope, *args)
    elif source["kind"] == "flatpakref":
        if exists and (changed or source_unverified):
            command(scope, "uninstall", "--noninteractive", ref)
            exists = False
        if not exists:
            command(scope, "install", "--noninteractive", "--from", source["path"])
        elif update_on_activation and app["commit"] is None:
            command(scope, "update", "--noninteractive", ref)
    else:
        if not exists:
            command(scope, "install", "--noninteractive", app["origin"], ref)
        elif app_origin(scope, ref, None) != app["origin"]:
            command(
                scope,
                "install",
                "--noninteractive",
                "--reinstall",
                app["origin"],
                ref,
            )
        elif update_on_activation and app["commit"] is None:
            command(
                scope,
                "install",
                "--noninteractive",
                "--or-update",
                app["origin"],
                ref,
            )

    if app["commit"] is not None and active_commit(scope, ref) != app["commit"]:
        update_to_commit(scope, ref, app["commit"], bundle_dir)
    if app["commit"] is not None:
        mask_add(scope, app["mask"])

    deployed_ref = output(scope, "info", ref, "--show-ref")
    if deployed_ref is None:
        raise RuntimeError(f"Flatpak did not install the declared ref: {ref}")
    deployed_origin = app_origin(scope, ref, app["origin"])
    if source["kind"] == "remote" and deployed_origin != app["origin"]:
        raise RuntimeError(
            f"Flatpak did not install {ref} from the declared origin: {app['origin']}"
        )

    return {
        "deployedRef": deployed_ref,
        "mask": app["mask"],
        "origin": deployed_origin,
        "sourceIdentity": identity,
        "sourceKind": source["kind"],
    }


def installed_app_refs(scope):
    value = output(scope, "list", "--app", "--columns=ref") or ""
    return {
        ref if ref.startswith("app/") else f"app/{ref}"
        for ref in value.splitlines()
        if ref
    }


def reconcile(manifest, scope, state_dir, override_dir):
    state_path = state_dir / "state.json"
    old = load_state(state_path)
    previous_apps = old_apps(old)
    previous_runtimes = old_runtimes(old)
    previous_remotes = old_remotes(old)
    previous_pins = set(old.get("pins", []))
    previous_runtime_pins = set(old.get("runtimePins", []))
    previous_runtime_package_pins = set(old.get("runtimePackagePins", []))
    desired_apps = {app["ref"]: app for app in manifest["apps"]}
    desired_runtimes = {
        runtime["ref"]: runtime for runtime in manifest.get("runtimePackages", [])
    }

    for ref, state in previous_apps.items():
        if ref in desired_apps:
            continue
        mask_remove(scope, state.get("mask", ref))
        if installed(scope, ref):
            command(scope, "uninstall", "--noninteractive", ref)

    for ref, state in previous_runtimes.items():
        if ref in desired_runtimes:
            continue
        mask_remove(scope, state.get("mask", ref))
        if installed(scope, ref):
            command(scope, "uninstall", "--noninteractive", ref)

    current_remotes = remote_details(scope)
    next_remotes = {}
    for name, remote in manifest["remotes"].items():
        identity = remote_identity(remote)
        previous = previous_remotes.get(name, {})
        previously_managed = name in previous_remotes
        previous_identity = previous.get("identity")
        previous_url = previous.get("url")
        url_drifted = (
            previous_url is not None and current_remotes.get(name) != previous_url
        )
        if name in current_remotes and (
            (previously_managed and previous_identity != identity) or url_drifted
        ):
            command(scope, "remote-delete", "--force", name)
            current_remotes.pop(name)
        if name not in current_remotes:
            add_remote(scope, name, remote)
            current_remotes = remote_details(scope)
        next_remotes[name] = {
            "identity": identity,
            "explicit": True,
            "url": current_remotes.get(name),
        }

    next_apps = {}
    for app in manifest["apps"]:
        next_apps[app["ref"]] = reconcile_app(
            scope,
            app,
            {"pins": previous_pins, **previous_apps},
            manifest["updateOnActivation"],
            manifest.get("bundleDir"),
        )
        if app["source"]["kind"] == "flatpakref":
            origin = next_apps[app["ref"]]["origin"]
            if origin:
                next_remotes.setdefault(origin, {"identity": None, "explicit": False})

    next_runtimes = {}
    for runtime in manifest.get("runtimePackages", []):
        next_runtimes[runtime["ref"]] = reconcile_app(
            scope,
            runtime,
            {"pins": previous_runtime_package_pins, **previous_runtimes},
            manifest["updateOnActivation"],
            manifest.get("bundleDir"),
        )

    desired_runtime_pins = {
        item["ref"]: item["commit"] for item in manifest["runtimes"]
    }
    for ref in previous_runtime_pins | set(desired_runtime_pins):
        mask_remove(scope, ref)
    for ref, commit in desired_runtime_pins.items():
        if not installed(scope, ref):
            continue
        if active_commit(scope, ref) != commit:
            update_to_commit(scope, ref, commit, manifest.get("bundleDir"))
        mask_add(scope, ref)

    if manifest["uninstallUnmanaged"]:
        desired_deployed_refs = {app["deployedRef"] for app in next_apps.values()}
        for ref in installed_app_refs(scope) - desired_deployed_refs:
            command(scope, "uninstall", "--noninteractive", ref)

    if manifest["uninstallUnused"]:
        command(scope, "uninstall", "--unused", "--noninteractive")

    current_remotes = remote_details(scope)
    for name in set(previous_remotes) - set(next_remotes):
        if name not in current_remotes:
            continue
        result = command(
            scope,
            "remote-delete",
            "--force" if manifest["uninstallUnmanaged"] else name,
            *([name] if manifest["uninstallUnmanaged"] else []),
            check=False,
        )
        if result.returncode != 0:
            next_remotes[name] = previous_remotes[name]

    if manifest["uninstallUnmanaged"]:
        current_remotes = remote_details(scope)
        for name in set(current_remotes) - set(next_remotes):
            command(scope, "remote-delete", "--force", name)

    reconcile_overrides(old, manifest, override_dir)

    state = {
        "version": 3,
        "apps": next_apps,
        "pins": [app["mask"] for app in manifest["apps"] if app["commit"] is not None],
        "runtimePins": sorted(desired_runtime_pins),
        "runtimes": next_runtimes,
        "runtimePackagePins": [
            runtime["mask"]
            for runtime in manifest.get("runtimePackages", [])
            if runtime["commit"] is not None
        ],
        "remotes": next_remotes,
        "overrides": {"settings": manifest["overrides"]["settings"]},
    }
    atomic_write_json(state_path, state)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: flatlock-reconcile MANIFEST")

    manifest_path = Path(sys.argv[1])
    with manifest_path.open() as handle:
        manifest = json.load(handle)

    installation = manifest.get("installation")
    with mutation_guard(installation) as paths:
        reconcile(manifest, paths.scope, paths.state_dir, paths.override_dir)


if __name__ == "__main__":
    main()
