{
  lib,
  pkgs,
  stateVersion,
  ...
}:

{
  imports = [
    ./programs
    ./desktop
  ];

  home = {
    stateVersion = lib.mkDefault stateVersion;

    # User-specific packages
    packages = with pkgs; [
      vim
      wget
      curl
      fastfetch
    ];
  };
}
