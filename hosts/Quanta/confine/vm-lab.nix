{ config, lib, pkgs, ... }:

let
  guestMount = pkgs.writeShellScriptBin "guest-mount" ''
    mkdir -p "$HOME/guest"
    exec memprocfs -device "''${VM_INSPECT_DEVICE:?}" -mount "$HOME/guest" "$@"
  '';

  guestGdb = pkgs.writeShellScriptBin "guest-gdb" ''
    exec gdb -ex "target remote ''${VM_INSPECT_GDB:?}" "$@"
  '';

  tools = pkgs.buildEnv {
    name = "vm-lab-tools";
    paths = [
      pkgs.memprocfs
      pkgs.gdb
      pkgs.radare2
      guestMount
      guestGdb
    ];
  };
  toolsDrv = builtins.unsafeDiscardStringContext tools.drvPath;
  toolsOut = builtins.unsafeDiscardStringContext tools.outPath;
  toolsAttr = "${config.my.flakePath}#nixosConfigurations.${config.networking.hostName}.config.system.build.vmLabTools";

  launcher = config.confine.packages.vm-lab.launcher;

  bashrc = pkgs.writeText "vm-lab-bashrc" ''
    if [ -f /etc/bashrc ]; then . /etc/bashrc; fi
    PATH=$VM_LAB_TOOLS/bin:$PATH
    PS1="\[\e[36m\][vm-lab $VM_INSPECT_DOMAIN]\[\e[0m\] $PS1"
  '';

  vmLab = pkgs.writeShellScriptBin "vm-lab" ''
    if [ "$#" -eq 0 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
      echo "usage: vm-lab DOMAIN [COMMAND...]"
      echo "A sandboxed shell, or COMMAND, with a running guest open for inspection."
      echo "  guest-mount   the guest's memory as files under ~/guest (MemProcFS), runs until stopped"
      echo "  guest-gdb     gdb on QEMU's debug stub, the guest stops while it is attached"
      echo "These, gdb and radare2 are fetched or built when the lab is first entered, more come with: nix shell nixpkgs#NAME"
      echo "Files kept in the sandbox's home are under ~/.local/share/confine/${config.confine.apps.vm-lab.appId}."
      exit 2
    fi
    domain=$1
    shift
    if [ "$#" -eq 0 ]; then
      set -- "''${SHELL:-/bin/sh}"
      case "''${1##*/}" in
        fish)
          set -- "$1" --init-command 'set -gx PATH $VM_LAB_TOOLS/bin $PATH; functions -q fish_prompt; and functions -c fish_prompt __vm_lab_prompt; function fish_prompt; set_color cyan; echo -n "[vm-lab $VM_INSPECT_DOMAIN] "; set_color normal; functions -q __vm_lab_prompt; and __vm_lab_prompt; end'
          ;;
        bash) set -- "$1" --rcfile ${bashrc} -i ;;
      esac
      echo "vm-lab: $domain is open in this shell, guest-mount and guest-gdb work here, exit closes it"
    fi
    links="''${XDG_CACHE_HOME:-$HOME/.cache}/vm-lab"
    ${pkgs.coreutils}/bin/mkdir -p "$links"
    nix=${config.nix.package}/bin/nix
    if ! "$nix" build ${toolsOut} --out-link "$links/tools" 2>/dev/null \
      && ! "$nix" build '${toolsDrv}^out' --out-link "$links/tools" 2>/dev/null \
      && ! "$nix" build ${lib.escapeShellArg toolsAttr} --out-link "$links/tools"; then
      echo "vm-lab: could not get the lab's tools" >&2
      exit 1
    fi
    export VM_LAB_TOOLS=${toolsOut}
    id=${pkgs.coreutils}/bin/id
    inspect=${config.my.virtualisation.inspect.package}/bin/vm-inspect
    mode=--gdb
    if "$inspect" --join "$domain" -- ${pkgs.coreutils}/bin/true 2>/dev/null; then
      mode=--join
    fi
    exec "$inspect" "$mode" "$domain" -- ${launcher}/bin/${launcher.name} \
      unshare --user --map-user="$($id -u)" --map-group="$($id -g)" --mount --keep-caps -- \
      /bin/sh -c 'PATH=$VM_LAB_TOOLS/bin:$PATH exec "$@"' sh "$@"
  '';
in
lib.mkIf config.my.virtualisation.inspect.enable {
  confine.apps.vm-lab = {
    package = pkgs.runCommand "vm-lab-env" { } "mkdir -p $out/bin";
    appId = "org.nixos.VmLab";
    install = false;
    linger = false;

    network = "isolated";
    seccomp.nesting = true;
    devices = [ "/dev/fuse" ];

    binds.ro = [
      "xdg-run/vm-inspect"
      "/run/vm-inspect"
      "/nix/var/nix/daemon-socket"
    ];
    env.NIX_REMOTE = "daemon";
    envPassthrough = [
      "COLORTERM"
      "NIX_PATH"
      "VM_INSPECT_DOMAIN"
      "VM_INSPECT_DIR"
      "VM_INSPECT_DEVICE"
      "VM_INSPECT_GDB"
      "VM_LAB_TOOLS"
    ];
  };

  system.build.vmLabTools = tools;

  environment.systemPackages = [ vmLab ];
}
