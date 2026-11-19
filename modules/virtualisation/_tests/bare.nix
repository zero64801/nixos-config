# nix build --no-link .#tests.virtualisation.bare
# Modules of this folder turned on in a fork that deleted something they read from.
{
  host,
}:

host.bare [
  {
    on = [ "modules/virtualisation/gpu-mode.nix" ];
    gone = "modules/virtualisation/desktop.nix";
    config.my.virtualisation.gpuMode = {
      enable = true;
      domains.guest = { };
    };
  }
  {
    on = [ "modules/virtualisation/desktop.nix" ];
    gone = "modules/virtualisation/gpu-switch.nix";
    config.my.virtualisation = {
      # What takes the line the desktop module writes for the cards, and so reads it.
      base.enable = true;
      desktop = {
        enable = true;
        vfio = {
          enable = true;
          ids = [ "10de:1b80" ];
        };
      };
    };
  }
  {
    on = [ "modules/virtualisation/gpu-switch.nix" ];
    gone = "modules/virtualisation/desktop.nix";
    config.my.virtualisation.gpuSwitch.enable = true;
    refused = "this system has no module with that option";
  }
]
