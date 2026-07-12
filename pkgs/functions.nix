inputs: final: prev:
let
  inherit (prev) lib;
in
{
  util = {
    importFlake = path:
      (import inputs.flake-compat { src = path; }).defaultNix;

    # Shared scaffold for the nyx CLI scripts. SC2034/SC2329 disabled because
    # not every script uses every color or helper.
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

        src = final.fetchzip { inherit url hash; };

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
