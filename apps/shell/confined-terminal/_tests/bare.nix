# nix build --no-link .#tests.confined-terminal.bare
# The confined terminal turned on in a fork that deleted confine, which it cannot do without and has to say so.
{
  host,
}:

host.bare [
  {
    on = [ "apps/shell/confined-terminal" ];
    gone = "apps/confine";
    config.my.apps.confinedTerminal.enable = true;
    refused = "this system has no confine module";
  }
]
