{ lib, pkgs, ... }:

{
  # Installed here so EDITOR/MANPAGER resolve on every host, root included.
  environment.systemPackages = [ pkgs.vim ];

  environment.variables = {
    # 900: above upstream's mkDefault nano, below any plain host override.
    EDITOR = lib.mkOverride 900 "vim";
    # vim's bundled manpager plugin; +Man! is neovim-only.
    MANPAGER = lib.mkDefault "vim -M +MANPAGER -";
  };

  programs.nano.enable = false;
}
