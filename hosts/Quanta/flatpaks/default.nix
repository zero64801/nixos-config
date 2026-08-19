{ config, lib, pkgs, ... }:

let
  # flatpak names the driver extension after the exact host driver version
  glNvidia = "nvidia-${lib.replaceStrings [ "." ] [ "-" ] config.hardware.nvidia.package.version}";
  glDrivers = "mesa-git:${glNvidia}";
in
{
  flatlock = {
    enable = true;
    lockFile = ./flatpak.lock;
    lockFileRelativePath = "hosts/Quanta/flatpaks/flatpak.lock";
    uninstallUnmanaged = true;
    # overrides live at the user (hm) level, so prune system override files left behind (e.g. the earlier system-level Steam/protontricks attempt)
    overrides.pruneRemoved = true;
  };

  /*
  Latest mesa for every flatpak: the beta repo's mesa-git builds publish
  under the stable 25.08 branch, matching the GL extension point of both
  the freedesktop 25.08 and gnome 50 runtimes in use here. Selected via
  FLATPAK_GL_DRIVERS, which flatpak reads at sandbox setup. Delete that
  line to fall back to the stable driver, which stays installed.

  The nvidia driver mounts alongside mesa for PRIME offload inside sandboxes.
  Apps stay on mesa via the inherited session ICD hiding from graphics.nix.
  */
  flatlock.runtimes = [
    {
      id = "org.freedesktop.Platform.GL.mesa-git";
      arch = "x86_64";
      branch = "25.08";
      origin = "flathub-beta";
    }
    {
      id = "org.freedesktop.Platform.GL32.mesa-git";
      arch = "x86_64";
      branch = "25.08";
      origin = "flathub-beta";
    }
    {
      id = "org.freedesktop.Platform.GL.${glNvidia}";
      arch = "x86_64";
      branch = "1.4";
      origin = "flathub";
    }
    {
      id = "org.freedesktop.Platform.GL32.${glNvidia}";
      arch = "x86_64";
      branch = "1.4";
      origin = "flathub";
    }
  ];

  environment.sessionVariables.FLATPAK_GL_DRIVERS = glDrivers;

  /*
  sessionVariables only land at login. Push the value into the running
  session's systemd and D-Bus activation environments on every switch so
  flatpaks launched afterwards already see it. Skipped when no session
  bus is up (headless switch). Removing the variable still needs a
  logout, the stale value just lingers until then.
  */
  hm.home.activation.flatpakGlDrivers =
    config.hm.lib.dag.entryAfter [ "writeBoundary" ] ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" \
          ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd \
          FLATPAK_GL_DRIVERS=${glDrivers} || true
      fi
    '';

  hm.flatlock = {
    enable = true;
    remotes = lib.mkForce { };
    lockFile = ./flatpak-user.lock;
    lockFileRelativePath = "hosts/Quanta/flatpaks/flatpak-user.lock";
    overrides.pruneRemoved = true;
  };
}
