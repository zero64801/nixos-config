# nix build --no-link .#tests.gpu-mode.bare
# GPU modes turned on in a fork that deleted the desktop module, which only names the cards a mode takes out by default.
{
  host,
}:

host.bare [
  {
    on = [ "modules/virtualisation/gpu-mode" ];
    gone = "modules/virtualisation/desktop";
    config.my.virtualisation.gpuMode = {
      enable = true;
      domains.guest = { };
    };
  }
]
