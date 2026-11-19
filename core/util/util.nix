{
  # What several things of this repository share, reached as pkgs.util.
  nixpkgs.overlays = [ (final: _: { util = import ./_util.nix final; }) ];
}
