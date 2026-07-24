{
  util,
  steamDisplayName ? "proton-cachyos-v3",
}:
let
  version = "cachyos-11.0-20260703-slr";
in
util.mkProtonBin {
  pname = "proton-cachyos-v3-bin";
  inherit version steamDisplayName;

  url = "https://github.com/CachyOS/proton-cachyos/releases/download/${version}/proton-${version}-x86_64_v3.tar.xz";
  hash = "sha256-8Y7orUvnFOG0zSqCrMyvmclmy3JInj7d8A2h0Y7RwhE=";
  vdfInternalName = "proton-${version}-x86_64_v3";

  description = ''
    Compatibility tool for Steam Play based on Wine and additional components.

    (This is intended for use in the `programs.steam.extraCompatPackages` option only.)
  '';
  homepage = "https://github.com/CachyOS/proton-cachyos";
}
