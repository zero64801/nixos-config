{ lib, ... }:

{
  environment.variables = {
    EDITOR = lib.mkForce "vim";
    MANPAGER = lib.mkForce "vim +Man!";
  };

  programs.nano.enable = false;
}
