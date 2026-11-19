# nix build --no-link .#tests.gaming.bare
# Gaming turned on in a fork that deleted the scheduler switch it reads from.
{
  host,
}:

host.bare [
  {
    on = [ "apps/gaming/gaming.nix" ];
    gone = "apps/gaming/scx";
    config.my.apps.gaming.enable = true;
  }
]
