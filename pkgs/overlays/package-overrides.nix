final: prev:
let
  pkgs-frozen = import final.sources.nixpkgs-frozen {
    system = prev.system;
    config.overlays = [ final.chaotic ];
  };
in
{
  linux-cachyos = pkgs-frozen.linux-cachyos;
}
