{
  config,
  inputs,
  lib,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkOption;
  inherit (lib.types) bool listOf nullOr path submodule;

  cfg = config.nyx.virtualisation.nixvirt;

  domainOpt = submodule {
    options = {
      definition = mkOption {
        type = path;
        description = "Path to the domain XML file (managed by NixVirt).";
      };
      active = mkOption {
        type = nullOr bool;
        default = null;
        description = "true = ensure running, false = ensure shut off, null = leave alone.";
      };
      restart = mkOption {
        type = nullOr bool;
        default = null;
        description = "true = always restart on rebuild, false = never, null = restart only when XML changes.";
      };
    };
  };
in
{
  imports = [ inputs.nixvirt.nixosModules.default ];

  options.nyx.virtualisation.nixvirt = {
    enable = mkEnableOption "declarative libvirt domain management via NixVirt";

    domains = mkOption {
      type = listOf domainOpt;
      default = [ ];
      description = "Domains to define declaratively at qemu:///system.";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.libvirt = {
      enable = true;
      swtpm.enable = true;
      connections."qemu:///system".domains = cfg.domains;
    };

    systemd.services.nixvirt.restartTriggers = map (d: d.definition) cfg.domains;
  };
}
