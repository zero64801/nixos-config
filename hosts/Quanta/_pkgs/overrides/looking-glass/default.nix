{ inputs, final, prev }:

let
  commit = "54ea580e35d8f3c96ab6177ff284d1d047796bf7";
  version = "B7-822-54ea580e";
  hash = "sha256-Z5+JfMuG4hVDjZber7pBwdiM/T45mve0/NWaMGL0E1k=";

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
