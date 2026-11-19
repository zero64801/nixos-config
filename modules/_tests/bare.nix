# nix build --no-link .#tests.modules.bare
# Modules of this folder turned on in a fork that deleted something they read from.
{
  host,
}:

host.bare [
  {
    on = [ "modules/yubikey.nix" ];
    gone = "modules/touch-guard";
    config.my.security.yubikey.enable = true;
  }
]
