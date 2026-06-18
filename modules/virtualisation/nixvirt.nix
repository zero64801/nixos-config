{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) getExe mkEnableOption mkIf mkOption;
  inherit (lib.types) bool listOf nullOr path submodule;

  cfg = config.nyx.virtualisation.nixvirt;

  # NixVirt redefines domains from the static XML on every (re)start, which
  # reverts the disk <source> to the base image and silently detaches any
  # external snapshot overlay. This repoints each domain's disks at its
  # current snapshot's overlay so writes keep landing on the chain tip.
  snapshotFixup = pkgs.writeShellApplication {
    name = "nixvirt-snapshot-fixup";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.virt-manager # virt-xml
      pkgs.xmlstarlet
      pkgs.gawk
    ];
    text = ''
      export LIBVIRT_DEFAULT_URI=qemu:///system
      for dom in $(virsh list --all --name); do
        cur=$(virsh snapshot-current --name "$dom" 2>/dev/null) || continue
        [ -n "$cur" ] || continue
        virsh snapshot-dumpxml "$dom" "$cur" \
          | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
              -v @name -o "|" -v "source/@file" -n \
          | while IFS="|" read -r target file; do
              [ -n "$target" ] && [ -n "$file" ] || continue
              active=$(virsh domblklist "$dom" | awk -v t="$target" '$1 == t { print $2 }')
              if [ "$active" != "$file" ]; then
                echo "$dom: repointing $target -> $file (snapshot $cur)"
                virt-xml "$dom" --edit target="$target" --disk path="$file"
              fi
            done
      done
    '';
  };

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

    systemd.services.nixvirt = {
      restartTriggers = map (d: d.definition) cfg.domains;
      # Runs after every redefine, so snapshot overlays survive rebuilds/boots.
      serviceConfig.ExecStartPost = getExe snapshotFixup;
    };
  };
}
