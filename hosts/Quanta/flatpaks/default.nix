{ lib, ... }:

{
  flatlock = {
    enable = true;
    lockFile = ./flatpak.lock;
    lockFileRelativePath = "hosts/Quanta/flatpaks/flatpak.lock";
  };

  hm.flatlock = {
    enable = true;
    remotes = lib.mkForce { };
  };
}
