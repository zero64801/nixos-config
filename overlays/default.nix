final: prev: {
  proton-cachyos-v3-bin = prev.callPackage ../pkgs/proton/proton-cachyos-v3.nix { };
  dwproton-bin = prev.callPackage ../pkgs/proton/dw-proton.nix { };
}
