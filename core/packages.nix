{ pkgs, lib, ... }:

{
  environment.systemPackages = with pkgs; [
    lsof
    git
  ];

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };
}
