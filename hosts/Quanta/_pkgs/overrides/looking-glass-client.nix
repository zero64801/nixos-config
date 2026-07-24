# Pin looking-glass-client to a custom upstream commit instead of the
# nixpkgs release tag. To bump: change commit + version, then refresh hash
# (`nix run nixpkgs#nurl -- https://github.com/gnif/LookingGlass <commit> --submodules=true`).
{ inputs, final, prev }:
let
  commit = "d3d1d48e97c47416e2e04662573d7484540e4a0a";
  version = "B7-355-d3d1d48e";
  hash = "sha256-kTsYNJzbyyhwid4BXu0CXLOZyg50rms2a9ml6Tru+bg=";
in
{
  looking-glass-client = prev.looking-glass-client.overrideAttrs (_: {
    inherit version;
    src = prev.fetchFromGitHub {
      owner = "gnif";
      repo = "LookingGlass";
      rev = commit;
      inherit hash;
      fetchSubmodules = true;
    };
  });
}
