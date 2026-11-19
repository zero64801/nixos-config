# nix build --no-link .#tests.gpu-switch.bare
# The GPU switch turned on in a fork that deleted the desktop module, which names the cards it switches, so it has to say so.
{
  host,
}:

host.bare [
  {
    on = [ "modules/virtualisation/gpu-switch" ];
    gone = "modules/virtualisation/desktop";
    config.my.virtualisation.gpuSwitch.enable = true;
    refused = "this system has no module with that option";
  }
]
