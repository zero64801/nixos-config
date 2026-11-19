# nix build --no-link -L .#tests.nixvirt.nixvirt-snapshot-menu
{
  host,
}:

let
  inherit (host) pkgs;
  inherit (pkgs) lib;

  # First on the tool's PATH: a virsh that answers only on the read only connection, and a sudo that records its command.
  fakeLibvirt = pkgs.symlinkJoin {
    name = "fake-libvirt";
    paths = [
      (pkgs.writeShellScriptBin "sudo" ''printf '%s\n' "$*" > "$SUDO_LOG"'')
      (pkgs.writeShellScriptBin "virsh" ''
        echo "$*" >> "$VIRSH_LOG"
        if [ "$1" != -r ]; then
          echo "error: authentication unavailable: no polkit agent available" >&2
          exit 1
        fi
        shift
        case "$1" in
          list) printf 'daily\ndeep\nlive\nplain\nodd\n\n' ;;
          domstate)
            case "$2" in
              live) echo running ;;
              odd) echo paused ;;
              *) echo "shut off" ;;
            esac
            ;;
          snapshot-current)
            case "$3" in
              daily|live|odd) echo safe0 ;;
              deep) echo c ;;
              *) echo "error: domain '$3' has no current snapshot" >&2; exit 1 ;;
            esac
            ;;
          snapshot-list)
            case "$2" in
              daily|live|odd) echo safe0 ;;
              deep) printf 'a\nb\nc\n' ;;
            esac
            ;;
          snapshot-dumpxml)
            parent=
            case "$3" in
              c) parent=b ;;
              b) parent=a ;;
            esac
            echo "<domainsnapshot><name>$3</name>''${parent:+<parent><name>$parent</name></parent>}<disks><disk name='sda' snapshot='external'><source file='/images/$2.$3'/></disk></disks></domainsnapshot>"
            ;;
          domblklist) printf ' Type   Device   Target   Source\n----\n file   disk     sda      /images/%s.qcow2\n' "$2" ;;
        esac
      '')
    ];
  };

  inherit
    (host.evaluate {
      config = {
        virtualisation.libvirtd.package = fakeLibvirt;
        my.virtualisation.nixvirt.enable = true;
      };
    })
    config
    ;

  tool = lib.findFirst (p: p.name == "nixvirt-snapshot") null config.environment.systemPackages;
in
pkgs.runCommand "nixvirt-snapshot-menu-test"
  {
    nativeBuildInputs = [
      tool
      (pkgs.python3.withPackages (ps: [ ps.pexpect ]))
    ];
  }
  ''
    export VIRSH_LOG=$PWD/virsh.log SUDO_LOG=$PWD/sudo.log
    python3 ${./nixvirt-snapshot-menu.py}
    touch $out
  ''
