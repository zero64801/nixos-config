# nix build --no-link .#tests.yubikey.bare
# YubiKey support turned on in a fork that deleted touch-guard, which it only reads to step aside for.
{
  host,
}:

host.bare [
  {
    on = [ "modules/yubikey" ];
    gone = "modules/touch-guard";
    config.my.security.yubikey.enable = true;
  }
]
