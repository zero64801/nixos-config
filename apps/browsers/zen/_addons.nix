# The addons a firefox-addons.json names, each as a package that puts its file where the browser looks for extensions.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

path:

let
  firefoxId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

  mkAddon = name: pin:
    stdenvNoCC.mkDerivation {
      pname = "firefox-addon-${name}";
      inherit (pin) version;

      src = fetchurl { inherit (pin) url sha256; };

      dontUnpack = true;
      preferLocalBuild = true;

      installPhase = ''
        runHook preInstall
        install -Dm444 "$src" \
          "$out/share/mozilla/extensions/${firefoxId}/${pin.addonId}.xpi"
        runHook postInstall
      '';

      passthru = { inherit (pin) addonId slug; };

      meta = {
        description = "Firefox addon ${name}";
        homepage = "https://addons.mozilla.org/firefox/addon/${pin.slug}/";
        platforms = lib.platforms.all;
      };
    };
in
lib.mapAttrs mkAddon (builtins.fromJSON (builtins.readFile path))
