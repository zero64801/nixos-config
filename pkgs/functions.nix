_inputs: final: prev:
let
  inherit (prev) lib;
in
{
  util = {
    importPins = path:
      lib.mapAttrs
        (_: pin: final.fetchFromGitHub { inherit (pin) owner repo rev hash; })
        (builtins.fromJSON (builtins.readFile path));

    importAddons = path:
      let
        firefoxId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

        mkAddon = name: pin:
          final.stdenvNoCC.mkDerivation {
            pname = "firefox-addon-${name}";
            inherit (pin) version;

            src = final.fetchurl { inherit (pin) url sha256; };

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
      lib.mapAttrs mkAddon (builtins.fromJSON (builtins.readFile path));

    cliPrelude = ''
      # shellcheck disable=SC2034,SC2329
      {
        red=$(tput setaf 1 || echo "")
        green=$(tput setaf 2 || echo "")
        yellow=$(tput setaf 3 || echo "")
        blue=$(tput setaf 4 || echo "")
        cyan=$(tput setaf 6 || echo "")
        reset=$(tput sgr0 || echo "")
        bold=$(tput bold || echo "")

        DIM='\x1b[2m'
        NC='\x1b[0m'
        MAGENTA='\x1b[0;35m'

        die()  { echo -e "''${red}Error:''${reset} $*" >&2; exit 1; }
        info() { echo -e "''${blue}::''${reset} $*"; }
        ok()   { echo -e "''${green}✓''${reset} $*"; }
        warn() { echo -e "''${yellow}⚠''${reset} $*"; }
      }
    '';

    mkProtonBin =
      {
        pname,
        version,
        url,
        hash,
        vdfInternalName,
        description,
        homepage,
        steamDisplayName,
        passthru ? { },
      }:
      final.stdenvNoCC.mkDerivation {
        inherit pname version passthru;

        src = final.fetchzip {
          name = "${pname}-${version}-source";
          inherit url hash;
        };

        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;

        outputs = [
          "out"
          "steamcompattool"
        ];

        installPhase = ''
          runHook preInstall

          echo "${pname} should not be installed into environments. Please use programs.steam.extraCompatPackages instead." > $out

          mkdir $steamcompattool
          ln -s $src/* $steamcompattool
          rm $steamcompattool/compatibilitytool.vdf
          cp $src/compatibilitytool.vdf $steamcompattool

          runHook postInstall
        '';

        preFixup = ''
          substituteInPlace "$steamcompattool/compatibilitytool.vdf" \
            --replace-fail "${vdfInternalName}" "${steamDisplayName}"
        '';

        meta = {
          inherit description homepage;
          license = lib.licenses.bsd3;
          maintainers = [ ];
          platforms = ["x86_64-linux"];
          sourceProvenance = [lib.sourceTypes.binaryNativeCode];
        };
      };
  };
}
