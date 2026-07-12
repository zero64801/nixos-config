{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    lsof
    git
  ];
}
