# nix build --no-link .#tests.desktop.bare
# Passthrough turned on in a fork that deleted the GPU switch, without which the cards stay with vfio from boot.
{
  host,
}:

host.bare [
  {
    on = [ "modules/virtualisation/desktop" ];
    gone = "modules/virtualisation/gpu-switch";
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
]
