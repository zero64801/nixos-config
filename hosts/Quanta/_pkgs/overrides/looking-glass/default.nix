{ inputs, final, prev }:

let
  commit = "7476e56ded94b7cadebdb12529636a30a66cb3fa";
  version = "B7-794-7476e56d";
  hash = "sha256-CRQURnhraZO6sI2/1CPDJELKUA5yuquIg1KxiU5EbxM=";

  src = final.fetchFromGitHub {
    owner = "gnif";
    repo = "LookingGlass";
    rev = commit;
    inherit hash;
    fetchSubmodules = true;
  };
in
{
  looking-glass-client = prev.looking-glass-client.overrideAttrs (oldAttrs: {
    inherit version src;

    patches = [ ];

    postPatch = (oldAttrs.postPatch or "") + ''
      substituteInPlace CMakeLists.txt \
        --replace-fail 'find_package(PkgConfig)' 'find_package(PkgConfig)
      find_package(NanoSVG REQUIRED)' \
        --replace-fail 'PkgConfig::FUSE3' 'PkgConfig::FUSE3
        NanoSVG::nanosvg'
      sed -i '/repos\/nanosvg\/src/d' CMakeLists.txt
    '';

    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
      final.fuse3
      final.libunwind
      final.elfutils
      final.usbredir
    ];
  });
}
