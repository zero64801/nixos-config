# nix build --no-link .#tests.scx.bare
# The scheduler switch turned on in a fork that deleted the module that says which cores guests hold.
{
  host,
}:

host.bare [
  {
    on = [ "apps/gaming/scx/default.nix" ];
    gone = "modules/virtualisation/cpu-pinning.nix";
    config.my.apps.scx.enable = true;
  }
]
