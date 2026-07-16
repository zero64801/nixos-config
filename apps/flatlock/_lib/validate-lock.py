import sys
from pathlib import Path

from runtime import FlatlockError, load_json, validate_lock


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: validate-lock LOCK_FILE...")
    try:
        for value in sys.argv[1:]:
            load_json(Path(value), validate=validate_lock)
    except FlatlockError as error:
        print(f"flatlock: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
