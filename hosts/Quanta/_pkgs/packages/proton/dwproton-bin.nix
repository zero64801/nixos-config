{
  util,
  writeScript,
  steamDisplayName ? "dwproton",
}:
let
  version = "dwproton-10.0-15";
in
util.mkProtonBin {
  pname = "dwproton-bin";
  inherit version steamDisplayName;

  url = "https://dawn.wine/dawn-winery/dwproton/releases/download/${version}/${version}-x86_64.tar.xz";
  hash = "sha256-Z59F/iLFM4CG7VAmGg74H7dpFhA4QveZgnXrkkUtwTI=";
  vdfInternalName = "${version}-x86_64";

  description = ''
    Compatibility tool for Steam Play based on Wine and additional components.

    (This is intended for use in the `programs.steam.extraCompatPackages` option only.)
  '';
  homepage = "https://dawn.wine/dawn-winery/dwproton";

  passthru.updateScript = writeScript "update-dwproton" ''
    #!/usr/bin/env nix-shell
    #!nix-shell -i bash -p curl jq common-updater-scripts
    repo="https://dawn.wine/api/v1/repos/dawn-winery/dwproton/releases/latest"
    version="$(curl -sL "$repo" | jq -r '.tag_name')"
    update-source-version dwproton-bin "$version"
  '';
}
