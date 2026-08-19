# nix build --impure --no-link --print-out-paths --expr 'import ./apps/confine/_tests/mock-app.nix { }'
# Needs a live session bus, compositor and sound server, so it cannot run at build time.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.writeShellApplication {
  name = "confine-mock-app";

  runtimeInputs = with pkgs; [
    coreutils
    dbus
    util-linux
    wayland-utils
    foot
    vulkan-tools
    pulseaudio
  ];

  text = ''
    say() { printf '  %-22s %s\n' "$1" "$2"; }

    # A sandbox that swallows a reply must surface as a timeout, not hang the probe.
    call() { timeout 8 dbus-send --print-reply "$@" >/dev/null 2>&1; }

    say wayland "$(timeout 8 wayland-info >/dev/null 2>&1 && echo ok || echo denied)"

    say gpu-vulkan "$(
      n=$(timeout 20 vulkaninfo --summary 2>/dev/null | grep -c deviceName || true)
      [ "''${n:-0}" -gt 0 ] && echo "ok ($n devices)" || echo denied
    )"

    # The document portal resolves the caller through bwrapinfo.json, a wrong pid fails the lookup.
    say portal-documents "$(
      call --session --dest=org.freedesktop.portal.Documents \
        /org/freedesktop/portal/documents \
        org.freedesktop.portal.Documents.GetMountPoint && echo ok || echo denied
    )"

    say portal-settings "$(
      call --session --dest=org.freedesktop.portal.Desktop \
        /org/freedesktop/portal/desktop \
        org.freedesktop.DBus.Properties.Get \
        string:org.freedesktop.portal.Settings string:version && echo ok || echo denied
    )"

    say notifications "$(
      call --session --dest=org.freedesktop.Notifications \
        /org/freedesktop/Notifications \
        org.freedesktop.Notifications.GetCapabilities && echo ok || echo denied
    )"

    # Never granted by any profile, denied here proves the bus filter is filtering.
    say kwin-control "$(
      call --session --dest=org.kde.KWin /KWin \
        org.freedesktop.DBus.Peer.Ping && echo REACHABLE || echo denied
    )"

    say audio-pulse "$(timeout 8 pactl info >/dev/null 2>&1 && echo ok || echo denied)"

    # What Chromium's zygote needs. Denied unless seccomp.nesting is on.
    say nested-userns "$(timeout 8 unshare -Ur true >/dev/null 2>&1 && echo ok || echo denied)"

    # wayland-info exits non-zero, under pipefail a pipe would falsely report denied.
    say clipboard-protocol "$(
      out=$(timeout 8 wayland-info 2>/dev/null || true)
      case "$out" in
        *ext_data_control_manager_v1*) echo REACHABLE ;;
        *) echo denied ;;
      esac
    )"

    say home-visible "$(
      n=$(find "$HOME" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
      echo "$n entries"
    )"

    # The portal validates the fd by resolving its path in the caller's namespace, so this needs a writable bind whose path is identical inside and out.
    say portal-identity "$(
      dir=""
      for candidate in "$HOME"/ConfinePortalTest "$HOME"/Downloads; do
        [ -d "$candidate" ] && [ -w "$candidate" ] && { dir=$candidate; break; }
      done
      if [ -z "$dir" ]; then
        echo "skipped (needs a writable bind)"
      elif ! command -v flatpak >/dev/null 2>&1; then
        echo "skipped (flatpak not in this package)"
      else
        f="$dir/.confine-identity-probe"
        printf 'probe\n' > "$f"
        if timeout 20 flatpak document-export "$f" >/dev/null 2>&1; then
          echo "exported, check: flatpak document-info $f"
        else
          echo denied
        fi
      fi
    )"

    say a11y-bus "$(
      if [ -z "''${AT_SPI_BUS_ADDRESS:-}" ]; then
        echo "not granted"
      elif timeout 8 dbus-send --bus="$AT_SPI_BUS_ADDRESS" --print-reply \
             --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
        echo ok
      else
        echo denied
      fi
    )"

    # Proves an actual rendered frame, not just a compositor connection.
    say window-render "$(
      timeout 25 foot --title=confine-mock -e true >/dev/null 2>&1 && echo ok || echo denied
    )"
  '';
}
