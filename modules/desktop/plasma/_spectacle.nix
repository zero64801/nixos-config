{
  lib,
  kdePackages,
  tesseractLanguages ? [ "eng" ],
  recording ? false,
}:

let
  # The Plasma releases the patches were run against. Any other gets each only where it still fits, since a Plasma update
  # must not fail a rebuild over them, and plasma.nix warns until that release is checked and listed here.
  checked = [ "6.8.2" ];
  known = lib.elem kdePackages.spectacle.version checked;

  patched =
    patch: old:
    if known then
      { patches = (old.patches or [ ]) ++ [ patch ]; }
    else
      {
        postPatch = (old.postPatch or "") + ''
          if patch -p1 -N --dry-run -i ${patch} > /dev/null; then
            patch -p1 -N -i ${patch}
          fi
        '';
      };

  scope = kdePackages.overrideScope (
    _: prev: {
      # Its frame limiter compares whole milliseconds with 16.67 and drops every third frame of a 60 fps stream.
      kpipewire = prev.kpipewire.overrideAttrs (patched ./_kpipewire-frame-limit.patch);
    }
  );

  spectacle = (if recording then scope else kdePackages).spectacle.override { inherit tesseractLanguages; };
in
spectacle.overrideAttrs (
  old:
  {
    passthru = (old.passthru or { }) // {
      recordingChecked = known;
      recordingLastChecked = lib.last checked;
    };
  }
  # Spectacle has no setting for the encoding quality, which is low by default, or for the size of a recorded region.
  // lib.optionalAttrs recording (patched ./_spectacle-recording.patch old)
)
