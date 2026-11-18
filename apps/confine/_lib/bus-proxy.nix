{ lib, xdg-dbus-proxy }:

let
  # Stock, a service in the sandbox cannot signal the caller it answers when that caller is in the sandbox too.
  siblings = ./dbus-proxy-siblings.patch;

  # The releases the patch was run against. Any other gets it only where it still fits, since a proxy update must not
  # fail a rebuild over it, and wrap.nix warns until that release is checked and listed here.
  checked = [ "0.1.9" ];
  known = lib.elem xdg-dbus-proxy.version checked;
in
xdg-dbus-proxy.overrideAttrs (
  old:
  {
    passthru = (old.passthru or { }) // {
      patchChecked = known;
      lastChecked = lib.last checked;
    };
  }
  // (
    if known then
      { patches = (old.patches or [ ]) ++ [ siblings ]; }
    else
      {
        postPatch = (old.postPatch or "") + ''
          if patch -p1 -N --dry-run -i ${siblings} > /dev/null; then
            patch -p1 -N -i ${siblings}
          fi
        '';
      }
  )
)
