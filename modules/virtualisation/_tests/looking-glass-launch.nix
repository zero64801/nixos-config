# nix build --impure --no-link -L --expr 'import ./modules/virtualisation/_tests/looking-glass-launch.nix { }'
{
  system ? (builtins.getFlake (toString ../../..)).nixosConfigurations.Quanta,
}:

let
  inherit (system) pkgs config;
  launcher = config.my.virtualisation.desktop.looking-glass.launcher;
  client = "${pkgs.looking-glass-client}/bin/looking-glass-client";
in
pkgs.runCommand "looking-glass-launch-test" { } ''
  set -euo pipefail
  state=$PWD/state
  stubs=$PWD/stubs
  mkdir -p "$state" "$stubs"

  cat > "$stubs/virsh" <<'EOF'
  #!${pkgs.runtimeShell}
  for a in "$@"; do last=$a; done
  case " $* " in
    *" list "*) cat "$STATE/running" ;;
    *" dumpxml "*) if grep -qx "$last" "$STATE/kvmfr"; then echo "<qemu:arg value='/dev/kvmfr0'/>"; else echo "<domain/>"; fi ;;
  esac
  EOF
  cat > "$stubs/client" <<'EOF'
  #!${pkgs.runtimeShell}
  echo "$*" > "$STATE/args"
  exec sleep 30
  EOF
  cat > "$stubs/notify-send" <<'EOF'
  #!${pkgs.runtimeShell}
  echo "$*" >> "$STATE/notified"
  EOF
  chmod +x "$stubs"/*

  sed -e "/^export PATH=/a export PATH=\"$stubs:\$PATH\"" -e "s|${client}|$stubs/client|g" \
    ${pkgs.lib.getExe launcher} > launch
  chmod +x launch
  export STATE=$state
  printf 'win11\nwin11-re\n' > "$state/kvmfr"

  fail() { echo "FAIL: $*"; exit 1; }

  start() {
    rm -f "$state/args" "$state/notified"
    ./launch "$@" &
    pid=$!
    for _ in $(seq 50); do [ -e "$state/args" ] && return; sleep 0.1; done
    fail "client did not start"
  }

  stop() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }

  shared() { ! grep -q "clipboard:toVM=no" "$state/args"; }

  closed_within() {
    for _ in $(seq $(( $1 * 10 ))); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    return 1
  }

  : > "$state/running"
  start
  shared && fail "clipboard shared with no guest running"
  stop; echo "ok   no guest: clipboard off"

  printf 'win11-re\n' > "$state/running"
  start
  shared && fail "clipboard shared with win11-re"
  stop; echo "ok   untrusted guest: clipboard off"

  printf 'win11\n' > "$state/running"
  start
  shared || fail "clipboard off for win11"
  printf 'win11\nwin11-re\n' > "$state/running"
  closed_within 4 || fail "client kept the clipboard after win11-re started"
  grep -q win11-re "$state/notified" || fail "no notification"
  stop; echo "ok   trusted guest: clipboard on, closed when win11-re starts"

  printf 'win11\n' > "$state/running"
  start
  printf 'win11\nlinux-re\n' > "$state/running"
  closed_within 3 && fail "client closed when a guest without kvmfr started"
  stop; echo "ok   a guest without kvmfr leaves the client alone"

  printf 'win11-re\n' > "$state/running"
  start --clipboard
  shared || fail "--clipboard did not share"
  printf 'win11-re\nwin11\n' > "$state/running"
  closed_within 4 || fail "--clipboard client kept running after win11 started"
  stop; echo "ok   --clipboard: on, closed when another kvmfr guest starts"

  : > "$state/running"
  start --clipboard
  printf 'win11\n' > "$state/running"
  closed_within 3 && fail "--clipboard client closed on the first guest"
  printf 'win11\nwin11-re\n' > "$state/running"
  closed_within 4 || fail "--clipboard client kept running after a second guest"
  stop; echo "ok   --clipboard with no guest adopts the first one"

  touch $out
''
