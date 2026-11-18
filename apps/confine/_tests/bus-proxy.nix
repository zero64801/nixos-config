# nix build --impure --no-link --expr 'import ./apps/confine/_tests/bus-proxy.nix { }'
# A proxy release newer than the patch was checked against is built with the patch where it still fits and as released
# where it does not, and fails in neither case.
{
  pkgs ? import <nixpkgs> { },
}:

let
  newer =
    change:
    pkgs.callPackage ../_lib/bus-proxy.nix {
      xdg-dbus-proxy = pkgs.xdg-dbus-proxy.overrideAttrs (
        old:
        {
          version = "999";
          inherit (pkgs.xdg-dbus-proxy) src;
        }
        // change old
      );
    };

  fitting = newer (_: { });
  # A rename of the kind a release could make: the code does the same and the lines around the patch are gone.
  drifted = newer (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i 's/unique_id_policy/id_policy/g' flatpak-proxy.c
    '';
  });
in
assert !fitting.patchChecked && !drifted.patchChecked;

pkgs.runCommand "confine-bus-proxy"
  {
    nativeBuildInputs = [
      pkgs.dbus
      (pkgs.python3.withPackages (p: [ p.jeepney ]))
    ];
    busConfig = "${pkgs.dbus}/share/dbus-1/session.conf";
    busPeers = ./bus-peers.py;
    inherit fitting drifted;
  }
  ''
    fail() {
      echo "confine: $*" >&2
      exit 1
    }
    await() {
      local tries=0
      until [ -e "$1" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt 100 ] || fail "$1 never appeared"
        sleep 0.1
      done
    }

    dbus-daemon --config-file="$busConfig" --address="unix:path=$TMPDIR/bus" --nofork 2> bus-err &
    bus=$!
    await "$TMPDIR/bus"

    # The exit status of a caller behind the proxy $1 whose service sits behind the same one.
    signalled() {
      local socket="$TMPDIR/$2" proxy service status=0
      "$1/bin/xdg-dbus-proxy" "unix:path=$TMPDIR/bus" "$socket" --filter '--own=com.test.Peer.*' &
      proxy=$!
      await "$socket"
      DBUS_SESSION_BUS_ADDRESS="unix:path=$socket" python3 -I "$busPeers" serve "com.test.Peer.$2" "$TMPDIR/$2-ready" &
      service=$!
      await "$TMPDIR/$2-ready"
      DBUS_SESSION_BUS_ADDRESS="unix:path=$socket" python3 -I "$busPeers" call "com.test.Peer.$2" || status=$?
      kill "$service" "$proxy"
      return "$status"
    }

    signalled "$fitting" Fitting || fail "a newer proxy the patch still fits was built without it"
    status=0
    signalled "$drifted" Drifted || status=$?
    [ "$status" -eq 3 ] || fail "a newer proxy the patch no longer fits does not behave as released (exit $status)"
    kill "$bus"
    touch "$out"
  ''
