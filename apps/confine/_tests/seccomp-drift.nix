# nix build --impure --no-link --expr 'import ./apps/confine/_tests/seccomp-drift.nix { }'
# Fails when the pinned flatpak filters a syscall _lib/seccomp.c never mentions.
# Upstream source is read, not compiled, to keep flatpak C out of the trust boundary.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.runCommand "confine-seccomp-drift"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.xz
    ];
    inherit (pkgs.flatpak) version;
  }
  ''
    tar xf ${pkgs.flatpak.src} --strip-components=1 --wildcards '*/common/flatpak-run*.c'

    names() {
      grep -ohE 'SCMP_SYS[[:space:]]*\([[:space:]]*[a-z0-9_]+' "$@" \
        | sed -E 's/.*\([[:space:]]*//' | sort -u
    }

    names common/flatpak-run*.c > upstream
    names ${../_lib/seccomp.c}   > ours

    missing=$(comm -23 upstream ours)

    if [ -n "$missing" ]; then
      echo "confine: flatpak $version filters syscalls this port does not mention:" >&2
      echo "$missing" | sed 's/^/  /' >&2
      echo "" >&2
      echo "Re-read setup_seccomp() in common/flatpak-run.c and update _lib/seccomp.c." >&2
      exit 1
    fi

    # Both forms reduce to syscall=errno, catching a verdict change names alone would miss.
    grep -ohE '\{[[:space:]]*SCMP_SYS[[:space:]]*\([[:space:]]*[a-z0-9_]+[[:space:]]*\)[[:space:]]*,[[:space:]]*E[A-Z]+' \
      common/flatpak-run*.c \
      | sed -E 's/.*\([[:space:]]*([a-z0-9_]+)[[:space:]]*\)[[:space:]]*,[[:space:]]*/\1=/' | sort -u > upstream-verdicts
    grep -ohE 'block[a-z_]*[[:space:]]*\([[:space:]]*E[A-Z]+,[[:space:]]*SCMP_SYS[[:space:]]*\([[:space:]]*[a-z0-9_]+' \
      ${../_lib/seccomp.c} \
      | sed -E 's/.*\([[:space:]]*(E[A-Z]+),[[:space:]]*SCMP_SYS[[:space:]]*\([[:space:]]*([a-z0-9_]+)/\2=\1/' | sort -u > our-verdicts

    changed=$(comm -23 upstream-verdicts our-verdicts)
    if [ -n "$changed" ]; then
      echo "confine: flatpak $version answers these differently from this port:" >&2
      echo "$changed" | sed 's/^/  upstream: /' >&2
      echo "$changed" | cut -d= -f1 | while read -r s; do
        grep "^$s=" our-verdicts | sed 's/^/  ours:     /' >&2 || true
      done
      exit 1
    fi

    {
      echo "checked against flatpak $version"
      echo "upstream syscalls: $(wc -l < upstream), all covered"
      echo "verdicts compared: $(wc -l < upstream-verdicts), all matching"
    } > "$out"
  ''
