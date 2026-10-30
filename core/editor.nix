{ lib, pkgs, ... }:

{
  environment.systemPackages = [ pkgs.vim ];

  environment.variables = {
    EDITOR = lib.mkOverride 900 "vim";
    MANPAGER = lib.mkDefault "vim -M +MANPAGER -";
  };

  programs.nano.enable = false;
}
