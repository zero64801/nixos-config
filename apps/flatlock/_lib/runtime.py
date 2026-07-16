import errno
import fcntl
import json
import os
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path


class FlatlockError(RuntimeError):
    pass


_EMPTY_UNSET = object()


@dataclass(frozen=True)
class ScopePaths:
    scope: str
    state_dir: Path
    override_dir: Path
    lock_path: Path


def command(scope, *args, check=True, capture=False):
    return subprocess.run(
        ["flatpak", scope, *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.DEVNULL if capture else None,
    )


def output(scope, *args):
    result = command(scope, *args, check=False, capture=True)
    return result.stdout.strip() if result.returncode == 0 else None


def installed(scope, ref):
    return output(scope, "info", ref, "--show-ref") is not None


def active_commit(scope, ref):
    return output(scope, "info", ref, "--show-commit")


def mask_remove(scope, pattern):
    subprocess.run(
        ["flatpak", scope, "mask", "--remove", pattern],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def mask_add(scope, pattern):
    command(scope, "mask", pattern)


def current_masks(scope):
    value = output(scope, "mask") or ""
    return {line.strip() for line in value.splitlines() if line.strip()}


def restore_masks(scope, expected):
    active = current_masks(scope)
    for pattern in active - expected:
        mask_remove(scope, pattern)
    for pattern in expected - active:
        mask_add(scope, pattern)


def scope_paths(installation):
    if installation == "system":
        return ScopePaths(
            scope="--system",
            state_dir=Path("/var/lib/flatlock"),
            override_dir=Path("/var/lib/flatpak/overrides"),
            lock_path=Path("/run/lock/flatlock-system.lock"),
        )
    if installation == "user":
        state_home = Path(
            os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")
        )
        data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        state_dir = state_home / "flatlock"
        return ScopePaths(
            scope="--user",
            state_dir=state_dir,
            override_dir=data_home / "flatpak/overrides",
            lock_path=state_dir / "mutation.lock",
        )
    raise FlatlockError("installation must be system or user")


def ensure_directory(path):
    path = Path(path)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        path.mkdir(parents=True)
        metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise FlatlockError(f"unsafe directory: {path}")
    return path


def ensure_regular_or_missing(path):
    path = Path(path)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise FlatlockError(f"unsafe file: {path}")


def open_regular(path):
    path = Path(path)
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise FlatlockError(f"unsafe file: {path}") from error
        raise
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        raise FlatlockError(f"unsafe file: {path}")
    return os.fdopen(descriptor)


def safe_child(directory, name):
    if not name or name in (".", "..") or Path(name).name != name:
        raise FlatlockError(f"unsafe file name: {name}")
    path = Path(directory) / name
    ensure_regular_or_missing(path)
    return path


def atomic_write_text(path, content, mode=0o644):
    path = Path(path)
    ensure_directory(path.parent)
    ensure_regular_or_missing(path)
    try:
        existing = path.lstat()
    except FileNotFoundError:
        existing = None
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        if existing is not None and os.geteuid() == 0:
            os.fchown(descriptor, existing.st_uid, existing.st_gid)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_write_json(path, value, mode=0o644):
    atomic_write_text(
        path,
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        mode,
    )


def validate_commit(value):
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdefABCDEF" for character in value)
    )


def validate_lock(value):
    if not isinstance(value, dict):
        raise FlatlockError("lock file must contain a JSON object")
    if "version" not in value:
        entries = list(value.items())
    else:
        if value.get("version") != 1:
            raise FlatlockError("lock file uses an unsupported version")
        apps = value.get("apps", {})
        runtimes = value.get("runtimes", {})
        if not isinstance(apps, dict) or not isinstance(runtimes, dict):
            raise FlatlockError("lock apps and runtimes must be JSON objects")
        entries = [*apps.items(), *runtimes.items()]
    if not all(
        isinstance(ref, str) and validate_commit(commit) for ref, commit in entries
    ):
        raise FlatlockError("lock entries must be 64 character hexadecimal commits")
    return value


def load_json(path, *, validate=None, missing=None, empty=_EMPTY_UNSET):
    path = Path(path)
    try:
        handle = open_regular(path)
    except FileNotFoundError:
        return missing
    try:
        with handle:
            contents = handle.read()
        if not contents.strip() and empty is not _EMPTY_UNSET:
            value = empty
        else:
            value = json.loads(contents)
    except json.JSONDecodeError as error:
        raise FlatlockError(f"invalid JSON in {path}: {error}") from error
    return validate(value) if validate is not None else value


def _open_lock(path):
    ensure_directory(path.parent)
    ensure_regular_or_missing(path)
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o660)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        raise FlatlockError(f"unsafe lock file: {path}")
    return os.fdopen(descriptor, "a+")


@contextmanager
def mutation_guard(installation):
    paths = scope_paths(installation)
    ensure_directory(paths.state_dir)
    with _open_lock(paths.lock_path) as lock_handle:
        fcntl.flock(lock_handle, fcntl.LOCK_EX)
        original_masks = current_masks(paths.scope)
        try:
            yield paths
        except BaseException:
            try:
                restore_masks(paths.scope, original_masks)
            except Exception as error:
                print(f"flatlock: could not restore masks: {error}", file=sys.stderr)
            raise
