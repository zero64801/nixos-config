{ ... }:

{
  imports = [
    ./system.nix
  ];

  home-manager.users.dx = import ./home-manager;
}
