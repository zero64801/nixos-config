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

  /*
  We use the created releases, and not the tags, for the update script as nix-update loads releases.atom
  that contains both. Sometimes upstream pushes the tags but the Github releases don't get created due to
  CI errors. Last time this happened was on 8-33, where a tag was created but no releases were created.
  As of 2024-03-13, there have been no announcements indicating that the CI has been fixed, and thus
  we avoid nix-update-script and use our own update script instead.
  See: <https://github.com/NixOS/nixpkgs/pull/294532#issuecomment-1987359650>
  */
  passthru.updateScript = writeScript "update-dwproton" ''
    #!/usr/bin/env nix-shell
    #!nix-shell -i bash -p curl jq common-updater-scripts
    repo="https://dawn.wine/api/v1/repos/dawn-winery/dwproton/releases/latest"
    version="$(curl -sL "$repo" | jq -r '.tag_name')"
    update-source-version dwproton-bin "$version"
  '';
}
