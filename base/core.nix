{ pkgs, lib, ... }:

{
  # Environment defaults
  environment = {
    systemPackages = with pkgs; [
      lsof
      git
    ];

    variables = {
      EDITOR = lib.mkForce "vim";
      MANPAGER = lib.mkForce "vim +Man!";
    };

    sessionVariables = {
      NIXOS_OZONE_WL = "1";
    };
  };

  # Disable nano in favor of vim
  programs.nano.enable = false;
}
