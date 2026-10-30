{ config, lib, pkgs, ... }:

let
  glNvidia = "nvidia-${lib.replaceStrings [ "." ] [ "-" ] config.hardware.nvidia.package.version}";
  glDrivers = "mesa-git:${glNvidia}";
in
{
  flatlock = {
    enable = true;
    lockFile = ./flatpak.lock;
    lockFileRelativePath = "hosts/Quanta/flatpaks/flatpak.lock";
    uninstallUnmanaged = true;
    overrides.pruneRemoved = true;
  };

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
