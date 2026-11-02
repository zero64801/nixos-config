{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) getExe mkEnableOption mkIf mkOption;
  inherit (lib.types)
    attrsOf
    bool
    enum
    ints
    listOf
    nullOr
    path
    str
    submodule
    ;

  cfg = config.my.virtualisation.nixvirt;

  hasData = cfg.dataDisks != { };
  hasCarry = cfg.carryOnRevert != { };
  dataUser = "nixvirt-guestfs";

  domainName =
    def:
    let
      after = lib.splitString "<name>" (builtins.readFile def);
    in
    if builtins.length after < 2 then
      null
    else
      lib.trim (builtins.head (lib.splitString "</name>" (builtins.elemAt after 1)));

  withDataDisk =
    d:
    let
      name = domainName d.definition;
      dd = cfg.dataDisks.${name} or null;
      prefix = if dd.bus == "virtio" then "vd" else "sd";
      sub = path: kind: n: v: [
        "-s"
        path
        "-t"
        kind
        "-n"
        n
        "-v"
        v
      ];
      args =
        sub "/domain/devices" "elem" "nvdata" ""
        ++ sub "//nvdata" "attr" "type" "file"
        ++ sub "//nvdata" "attr" "device" "disk"
        ++ sub "//nvdata" "attr" "snapshot" "no"
        ++ sub "//nvdata" "elem" "driver" ""
        ++ sub "//nvdata/driver" "attr" "name" "qemu"
        ++ sub "//nvdata/driver" "attr" "type" "raw"
        ++ sub "//nvdata/driver" "attr" "cache" "none"
        ++ sub "//nvdata/driver" "attr" "io" "native"
        ++ sub "//nvdata/driver" "attr" "discard" "unmap"
        ++ sub "//nvdata" "elem" "source" ""
        ++ sub "//nvdata/source" "attr" "file" dd.image
        ++ sub "//nvdata" "elem" "target" ""
        ++ sub "//nvdata/target" "attr" "bus" dd.bus
        # An SSD rotation rate keeps Windows from defragmenting the disk, which would rewrite every revision's blocks.
        ++ lib.optionals (dd.bus != "virtio") (sub "//nvdata/target" "attr" "rotation_rate" "1")
        ++ lib.optionals (dd.serial != null) (sub "//nvdata" "elem" "serial" dd.serial)
        ++ lib.optionals (dd.vendor != null) (sub "//nvdata" "elem" "vendor" dd.vendor)
        ++ lib.optionals (dd.product != null) (sub "//nvdata" "elem" "product" dd.product);
    in
    if dd == null then
      d
    else
      d
      // {
        definition =
          pkgs.runCommand "${name}.xml"
            {
              nativeBuildInputs = [
                pkgs.xmlstarlet
                pkgs.libxml2
                config.virtualisation.libvirtd.package
              ];
            }
            ''
              src=${d.definition}
              if xmlstarlet sel -t -m "/domain/devices/disk/source" -v @file -n "$src" | grep -qxF ${lib.escapeShellArg dd.image}; then
                echo "${name}: the domain XML already attaches ${dd.image}; remove that disk, the data disk config adds it" >&2
                exit 1
              fi
              used=$(xmlstarlet sel -t -m "/domain/devices/disk/target" -v @dev -n "$src")
              dev=""
              for c in b c d e f g h i j k l m n o p q r s t u v w x y z; do
                if ! printf '%s\n' "$used" | grep -qx "${prefix}$c"; then dev="${prefix}$c"; break; fi
              done
              [ -n "$dev" ] || { echo "${name}: no free ${prefix}? target for the data disk" >&2; exit 1; }
              xmlstarlet ed ${lib.escapeShellArgs args} \
                -s //nvdata/target -t attr -n dev -v "$dev" \
                -r //nvdata -v disk "$src" > $out
              virt-xml-validate $out domain
            '';
      };

  domains = map withDataDisk cfg.domains;

  definitionOf =
    n: (lib.findFirst (d: domainName d.definition == n) { definition = null; } cfg.domains).definition;

  relativePath =
    p:
    lib.all (
      c:
      !builtins.elem c [
        ""
        "."
        ".."
      ]
    ) (lib.splitString "/" p);

  dataConfig = pkgs.writeText "nixvirt-data.json" (
    builtins.toJSON {
      user = dataUser;
      appliance = "${pkgs.libguestfs-appliance}";
      domains = lib.mapAttrs (n: dd: dd // { definition = definitionOf n; }) cfg.dataDisks;
      carry = lib.mapAttrs (n: c: c // { definition = definitionOf n; }) cfg.carryOnRevert;
    }
  );

  dataPython = pkgs.python3.withPackages (ps: [ ps.guestfs ]);

  nixvirtData = pkgs.writeShellApplication {
    name = "nixvirt-data";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.qemu
      pkgs.coreutils
      pkgs.util-linux
      pkgs.less
    ];
    text = ''
      export LIBVIRT_DEFAULT_URI=qemu:///system
      exec ${dataPython}/bin/python3 ${./_nixvirt-data.py} ${dataConfig} "$@"
    '';
  };

  nixvirtResize = pkgs.writeShellApplication {
    name = "nixvirt-resize";
    text = ''
      if [ "$#" -lt 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        exec ${getExe nixvirtData} resize --help
      fi
      exec ${getExe nixvirtData} resize "$@"
    '';
  };

  # Runs inside nixvirt-snapshot revert, after the target snapshot is resolved and before the confirmation.
  revertDataReview = lib.optionalString hasData ''
    if [ "$no_data" -eq 0 ] && nixvirt-data has "$dom"; then
      tsnap=$(virsh snapshot-dumpxml "$dom" "$target")
      pairs=()
      while IFS="|" read -r tdev _; do
        [ -n "$tdev" ] || continue
        pbase=$(printf '%s\n' "$tsnap" | xmlstarlet sel -t \
          -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev' and @device='disk']" -v "source/@file" -n)
        plive=$(virsh domblklist "$dom" --inactive | awk -v t="$tdev" '$1 == t { print $2 }')
        if [ -n "$pbase" ] && [ -n "$plive" ] && [ "$pbase" != "$plive" ]; then
          pairs+=(--c-pair "$plive" "$pbase")
        fi
      done < <(printf '%s\n' "$tsnap" \
        | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" -v @name -o "|" -v "source/@file" -n)
      rc=0
      nixvirt-data review "$dom" "''${pairs[@]}" || rc=$?
      case "$rc" in
        0) echo ;;
        10) echo "aborted; nothing was reverted."; exit 0 ;;
        *) echo "data disk review failed; nothing was reverted (--no-data skips the review)" >&2; exit 1 ;;
      esac
    fi
  '';

  # Runs inside nixvirt-snapshot revert after the confirmation and before anything is discarded, so an abort or a failure reverts nothing.
  revertCarry = lib.optionalString hasCarry ''
    if [ "$no_carry" -eq 0 ] && nixvirt-data has-carry "$dom"; then
      csnap=$(virsh snapshot-dumpxml "$dom" "$target")
      while IFS="|" read -r tdev overlay; do
        [ -n "$tdev" ] && [ -n "$overlay" ] || continue
        cbase=$(printf '%s\n' "$csnap" | xmlstarlet sel -t \
          -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev' and @device='disk']" -v "source/@file" -n)
        clive=$(virsh domblklist "$dom" --inactive | awk -v t="$tdev" '$1 == t { print $2 }')
        [ -n "$cbase" ] && [ -n "$clive" ] && [ "$cbase" != "$clive" ] || continue
        rm -f "$overlay.carry"
        rc=0
        nixvirt-data revert-carry "$dom" --disk "$tdev" --pair "$clive" "$cbase" --into "$overlay.carry" || rc=$?
        case "$rc" in
          0) ;;
          10) rm -f "$overlay.carry"; echo "aborted; nothing was reverted."; exit 0 ;;
          *) rm -f "$overlay.carry"; echo "carrying changes failed; nothing was reverted (--no-carry skips carrying)" >&2; exit 1 ;;
        esac
      done < <(printf '%s\n' "$csnap" \
        | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" -v @name -o "|" -v "source/@file" -n)
    fi
  '';

  # Safe only because snapshotFixup runs at ExecStartPost after every declarative domain is defined, so an unreferenced *.fd belongs to a removed domain.
  nvramReaper = lib.optionalString cfg.reapNvram ''
    nvdir=/var/lib/libvirt/qemu/nvram
    if [ -d "$nvdir" ]; then
      referenced=$(for rd in $(virsh list --all --name); do
        [ -n "$rd" ] || continue
        virsh dumpxml "$rd" --inactive 2>/dev/null \
          | xmlstarlet sel -t -v "/domain/os/nvram" -n 2>/dev/null || true
      done | grep . || true)
      for f in "$nvdir"/*.fd; do
        [ -e "$f" ] || continue
        if ! printf '%s\n' "$referenced" | grep -qxF "$f"; then
          echo "reaping orphaned nvram: $f"
          rm -f "$f"
        fi
      done
    fi
  '';

  snapshotFixup = pkgs.writeShellApplication {
    name = "nixvirt-snapshot-fixup";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.xmlstarlet
      pkgs.gawk
      pkgs.coreutils
    ];
    text = ''
      export LIBVIRT_DEFAULT_URI=qemu:///system

      # Not virt-xml, which edits only <source> and leaves a stale <backingStore> that ends up pointing at itself and stops the VM from booting.
      redefine_disk() {
        local dom="$1" target="$2" file="$3" tmpf
        tmpf=$(mktemp)
        virsh dumpxml "$dom" --inactive --security-info \
          | xmlstarlet ed \
              -u "/domain/devices/disk[target/@dev='$target']/source/@file" -v "$file" \
              -d "/domain/devices/disk[target/@dev='$target']/backingStore" \
          > "$tmpf"
        virsh define "$tmpf" >/dev/null
        rm -f "$tmpf"
      }

      for dom in $(virsh list --all --name); do
        if virsh dumpxml "$dom" --inactive 2>/dev/null | grep -q "<backingStore"; then
          echo "$dom: stripping stale explicit backingStore element(s)"
          tmpf=$(mktemp)
          virsh dumpxml "$dom" --inactive --security-info \
            | xmlstarlet ed -d "/domain/devices/disk/backingStore" > "$tmpf"
          virsh define "$tmpf" >/dev/null
          rm -f "$tmpf"
        fi

        cur=$(virsh snapshot-current --name "$dom" 2>/dev/null) || continue
        [ -n "$cur" ] || continue
        virsh snapshot-dumpxml "$dom" "$cur" \
          | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
              -v @name -o "|" -v "source/@file" -n \
          | while IFS="|" read -r target file; do
              [ -n "$target" ] && [ -n "$file" ] || continue
              # Compare the inactive config because a running domain shows the overlay as its active disk, which masks a stale persistent base until the next shutdown.
              persistent=$(virsh domblklist "$dom" --inactive | awk -v t="$target" '$1 == t { print $2 }')
              if [ "$persistent" != "$file" ]; then
                echo "$dom: repointing $target -> $file (snapshot $cur)"
                redefine_disk "$dom" "$target" "$file"
              fi
            done
      done

      ${nvramReaper}
    '';
  };

  nixvirtSnapshot = pkgs.writeShellApplication {
    name = "nixvirt-snapshot";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.qemu
      pkgs.xmlstarlet
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.util-linux
    ]
    ++ lib.optional (hasData || hasCarry) nixvirtData;
    text = ''
      export LIBVIRT_DEFAULT_URI=qemu:///system

      usage() {
        cat <<EOF
      usage: nixvirt-snapshot <command> ...

        create  [-y] [--mem[=file]] [--internal] <domain> [name]
                                                         create a snapshot (defaults: external, disk-only; --mem adds RAM state, --internal stores inside the qcow2)
        commit  [-y] [-a|--all] [--to <snap>] <domain>   merge snapshot overlay(s) down into their base (alias: flatten)
        rotate  [-y] [--as <new>] <domain> [name]        commit through snapshot [name] (default: current), then recreate it (renamed to <new> if given)
        revert  [-y] [--no-data] [--no-carry] <domain> [name]
                                                         restore the disk state saved by snapshot [name] (default: current), discarding newer changes (VM must be off);
                                                         a domain with a data disk reviews it first (--no-data skips that), and one with
                                                         carryOnRevert paths reviews their changes for the fresh layer (--no-carry skips that)
        delete  [-y] <domain> [name]                     delete snapshot [name] (default: current), KEEPING current data: external merges down (like virt-manager), internal via virsh
        list    <domain>                                 show the snapshot chain and live disk state
      EOF
      }

      confirm() {
        if [ "$assume_yes" -eq 1 ]; then return 0; fi
        if [ ! -e /dev/tty ]; then
          echo "non-interactive (no tty) and no -y/--yes given; aborting." >&2
          exit 1
        fi
        local reply
        printf '%s [y/N] ' "$1"
        read -r reply </dev/tty || reply=""
        case "$reply" in
          y|Y|yes|YES) return 0 ;;
          *) echo "aborted; nothing was changed."; exit 0 ;;
        esac
      }

      vsize() {
        qemu-img info -U "$1" 2>/dev/null | sed -n 's/^virtual size: .*(\([0-9]*\) bytes)$/\1/p'
      }

      # Not virt-xml, which edits only <source> and leaves a stale <backingStore> that ends up pointing at itself and stops the VM from booting.
      repoint_disk() {
        local tdev="$1" newpath="$2" tmpf
        tmpf=$(mktemp)
        virsh dumpxml "$dom" --inactive --security-info \
          | xmlstarlet ed \
              -u "/domain/devices/disk[target/@dev='$tdev']/source/@file" -v "$newpath" \
              -d "/domain/devices/disk[target/@dev='$tdev']/backingStore" \
          > "$tmpf"
        virsh define "$tmpf" >/dev/null
        rm -f "$tmpf"
      }

      assume_yes=0
      all=0
      to=""
      as_name=""
      mem=0
      mempath=""
      internal=0
      no_data=0
      no_carry=0
      pos=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -h|--help) usage; exit 0 ;;
          -y|--yes) assume_yes=1 ;;
          --no-data) no_data=1 ;;
          --no-carry) no_carry=1 ;;
          -a|--all) all=1 ;;
          --to)
            if [ "$#" -lt 2 ]; then echo "--to requires a snapshot name" >&2; exit 1; fi
            to="$2"
            shift
            ;;
          --to=*) to="''${1#--to=}" ;;
          --as)
            if [ "$#" -lt 2 ]; then echo "--as requires a snapshot name" >&2; exit 1; fi
            as_name="$2"
            shift
            ;;
          --as=*) as_name="''${1#--as=}" ;;
          --mem) mem=1 ;;
          --mem=*) mem=1; mempath="''${1#--mem=}" ;;
          --internal) internal=1 ;;
          *) pos+=("$1") ;;
        esac
        shift
      done
      sub="''${pos[0]:-}"
      dom="''${pos[1]:-}"
      case "$sub" in
        flatten) sub=commit ;;
        create|commit|rotate|revert|delete|list) ;;
        *) usage >&2; exit 1 ;;
      esac
      [ -n "$dom" ] || { usage >&2; exit 1; }
      if [ "$all" -eq 1 ] && [ -n "$to" ]; then
        echo "--all and --to are mutually exclusive" >&2
        exit 1
      fi
      if [ -n "$as_name" ] && [ "$sub" != "rotate" ]; then
        echo "--as only applies to rotate" >&2
        exit 1
      fi
      if { [ "$no_data" -eq 1 ] || [ "$no_carry" -eq 1 ]; } && [ "$sub" != "revert" ]; then
        echo "--no-data and --no-carry only apply to revert" >&2
        exit 1
      fi
      if { [ "$mem" -eq 1 ] || [ "$internal" -eq 1 ]; } && [ "$sub" != "create" ]; then
        echo "--mem/--internal only apply to create" >&2
        exit 1
      fi
      if [ "$mem" -eq 1 ] && [ "$internal" -eq 1 ]; then
        echo "--mem does not apply to --internal (a running internal checkpoint includes memory automatically)" >&2
        exit 1
      fi

      if [ "$(id -u)" -ne 0 ]; then echo "run as root: sudo nixvirt-snapshot $sub $dom" >&2; exit 1; fi

      if [ "$sub" != "list" ]; then
        exec 9>"/run/lock/nixvirt-snapshot.$dom.lock"
        if ! flock -n 9; then
          echo "another nixvirt-snapshot operation is already running for '$dom'" >&2
          exit 1
        fi

        # Offline qemu-img and nbd surgery bypasses QEMU's runtime write lock, so refuse while another live domain shares a disk image.
        while read -r src; do
          [ -n "$src" ] || continue
          while read -r other; do
            [ -n "$other" ] && [ "$other" != "$dom" ] || continue
            if virsh domblklist "$other" 2>/dev/null | awk '{print $2}' | grep -qxF "$src"; then
              ostate=$(virsh domstate "$other" 2>/dev/null || true)
              case "$ostate" in
                running|paused)
                  echo "domain '$other' ($ostate) uses the same disk image: $src" >&2
                  echo "shut it down before operating on '$dom'" >&2
                  exit 1
                  ;;
              esac
            fi
          done < <(virsh list --all --name)
        done < <(virsh domblklist "$dom" --details 2>/dev/null | tail -n +3 | awk '$1=="file" && $2=="disk" {print $4}')
      fi

      if [ "$sub" = "list" ]; then
        state=$(virsh domstate "$dom" 2>/dev/null || true)
        cnt=$(virsh snapshot-list "$dom" --name 2>/dev/null | grep -c . || true)
        cur=$(virsh snapshot-current --name "$dom" 2>/dev/null || true)
        echo "domain: $dom (''${state:-unknown})"
        echo "snapshots: ''${cnt:-0}''${cur:+  (current: $cur)}"
        virsh snapshot-list "$dom" --tree 2>/dev/null | sed '/^$/d; s/^/  /'
        if [ "''${cnt:-0}" -gt 0 ]; then
          echo "snapshot overlays (allocated = changes held on that layer):"
          while read -r sname; do
            [ -n "$sname" ] || continue
            while read -r f; do
              [ -n "$f" ] || continue
              if [ -f "$f" ]; then
                sz=$(du -h "$f" 2>/dev/null | cut -f1)
              else
                sz="MISSING"
              fi
              echo "  [$sname] $f ($sz)"
            done < <(virsh snapshot-dumpxml "$dom" "$sname" 2>/dev/null \
              | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" -v "source/@file" -n 2>/dev/null || true)
          done < <(virsh snapshot-list "$dom" --name 2>/dev/null)
        fi
        echo "live disks:"
        while read -r ttype device tdev src; do
          [ -n "$tdev" ] || continue
          [ "$ttype" = "file" ] || continue
          sz=""
          if [ "$device" = "disk" ] && [ -f "$src" ]; then
            sz="  ($(du -h "$src" 2>/dev/null | cut -f1))"
          fi
          echo "  $tdev  $src$sz"
        done < <(virsh domblklist "$dom" --details 2>/dev/null | tail -n +3)
        exit 0
      fi

      if [ "$sub" = "create" ]; then
        state=$(virsh domstate "$dom" 2>/dev/null || true)
        case "$state" in
          running|"shut off") ;;
          *) echo "domain '$dom' must be running or shut off (state: ''${state:-unknown})" >&2; exit 1 ;;
        esac
        name="''${pos[2]:-snap-$(date +%Y%m%d-%H%M%S)}"
        if [ "$internal" -eq 1 ]; then
          if [ "$state" = "running" ]; then
            echo "Creating internal checkpoint '$name' of '$dom' (disk+memory inside the qcow2; the VM pauses while RAM is saved)."
            echo "note: fails while a VFIO device (GPU) is attached."
          else
            echo "Creating internal disk snapshot '$name' of '$dom' (stored inside the qcow2)."
          fi
          confirm "Proceed?"
          virsh snapshot-create-as "$dom" "$name" --atomic
        elif [ "$mem" -eq 1 ]; then
          if [ "$state" != "running" ]; then
            echo "--mem requires a running domain (RAM state only exists while running)" >&2
            exit 1
          fi
          if [ -z "$mempath" ]; then
            firstdisk=$(virsh domblklist "$dom" --details 2>/dev/null | awk '$2 == "disk" { print $4; exit }')
            if [ -z "$firstdisk" ]; then
              echo "could not determine a disk directory for the auto memory path; pass --mem=<file>" >&2
              exit 1
            fi
            mempath="$(dirname "$firstdisk")/$dom-mem.$name"
          fi
          cargs=(--memspec "file=$mempath,snapshot=external" --atomic)
          # Disks marked snapshot="no", like a data disk, keep their domain default.
          while read -r tdev; do
            [ -n "$tdev" ] || continue
            cargs+=(--diskspec "$tdev,snapshot=external")
          done < <(virsh dumpxml "$dom" 2>/dev/null \
            | xmlstarlet sel -t -m "/domain/devices/disk[@device='disk' and not(@snapshot='no')]" -v "target/@dev" -n)
          echo "Creating external disk+memory snapshot '$name' of '$dom'."
          echo "RAM state -> $mempath"
          echo "note: fails while a VFIO device (GPU) is attached (RAM saving uses the blocked migration machinery)."
          confirm "Proceed?"
          virsh snapshot-create-as "$dom" "$name" "''${cargs[@]}"
        else
          echo "Creating external disk-only snapshot '$name' of '$dom' ($state)."
          if [ "$state" = "running" ]; then
            echo "The VM stays on; the snapshot is crash-consistent (like a power cut at this instant)."
          fi
          confirm "Proceed?"
          virsh snapshot-create-as "$dom" "$name" --disk-only --atomic
        fi

        # NixVirt resets the persistent disk source to the base on every service start, so repoint it now or a rebuild or shutdown before the next snapshotFixup surfaces a stale base.
        if [ "$internal" -ne 1 ]; then
          while IFS="|" read -r tdev file; do
            [ -n "$tdev" ] && [ -n "$file" ] || continue
            cur_src=$(virsh domblklist "$dom" --inactive | awk -v t="$tdev" '$1 == t { print $2 }')
            if [ "$cur_src" != "$file" ]; then
              repoint_disk "$tdev" "$file"
              echo "$dom: persistent config for $tdev -> $file"
            fi
          done < <(virsh snapshot-dumpxml "$dom" "$name" 2>/dev/null \
            | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
                -v @name -o "|" -v "source/@file" -n 2>/dev/null || true)
        fi

        echo
        echo "Snapshot chain is now:"
        virsh snapshot-list "$dom" --tree 2>/dev/null | sed '/^$/d; s/^/  /'
        exit 0
      fi

      state=$(virsh domstate "$dom" 2>/dev/null || true)
      case "$state" in
        "shut off") live=0 ;;
        running)
          live=1
          case "$sub" in
            commit|rotate)
              echo "domain '$dom' is running — using live blockcommit (QEMU merges internally, no downtime)."
              echo
              ;;
          esac
          ;;
        *)
          echo "domain '$dom' must be shut off or running (state: ''${state:-unknown})" >&2
          exit 1
          ;;
      esac

      cur=$(virsh snapshot-current --name "$dom" 2>/dev/null || true)
      if [ -z "$cur" ]; then
        if [ "$sub" = "rotate" ]; then
          rotname="''${pos[2]:-''${as_name:-}}"
          [ -n "$rotname" ] || { echo "rotate: no snapshots exist — pass a name to create the first one" >&2; exit 1; }
          confirm "No snapshots exist; create snapshot '$rotname' of '$dom'?"
          virsh snapshot-create-as "$dom" "$rotname" --disk-only --atomic
          exit 0
        fi
        if [ "$sub" = "revert" ]; then
          echo "$dom has no snapshots — nothing to revert to" >&2
          exit 1
        fi
        if [ "$sub" = "delete" ]; then
          echo "$dom has no snapshots — nothing to delete" >&2
          exit 1
        fi
        echo "$dom has no current snapshot — nothing to commit" >&2
        exit 0
      fi

      snap_count=$(virsh snapshot-list "$dom" --name 2>/dev/null | grep -c . || true)
      echo "Snapshot chain for '$dom' ($snap_count total, current: $cur):"
      virsh snapshot-list "$dom" --tree 2>/dev/null | sed '/^$/d; s/^/  /'
      echo

      plan=()
      mismatch=0
      multilayer=0
      memfile=""

      walk_chain() {
        local n="$cur" i=0
        while [ -n "$n" ] && [ "$i" -le $((snap_count + 1)) ]; do
          printf '%s\n' "$n"
          i=$((i + 1))
          n=$(virsh snapshot-dumpxml "$dom" "$n" 2>/dev/null \
            | xmlstarlet sel -t -v "/domainsnapshot/parent/name" 2>/dev/null || true)
        done
      }
      mapfile -t chain_path < <(walk_chain)

      if [ "$sub" = "revert" ]; then
        if [ "$all" -eq 1 ] || [ -n "$to" ]; then
          echo "revert takes a snapshot name argument; --all/--to do not apply" >&2
          exit 1
        fi
        if [ "$live" -eq 1 ]; then
          echo "revert requires the domain shut off" >&2
          exit 1
        fi
        target="''${pos[2]:-$cur}"
        tidx=-1
        i=0
        for s in "''${chain_path[@]}"; do
          if [ "$s" = "$target" ]; then tidx=$i; break; fi
          i=$((i + 1))
        done
        if [ "$tidx" -lt 0 ]; then
          if virsh snapshot-info "$dom" "$target" >/dev/null 2>&1; then
            echo "snapshot '$target' exists but is not on the current chain (another branch?)" >&2
          else
            echo "no such snapshot: '$target'" >&2
          fi
          exit 1
        fi

        tmem=""
        for ((i = 0; i <= tidx; i++)); do
          sname="''${chain_path[i]}"
          sxml=$(virsh snapshot-dumpxml "$dom" "$sname" 2>/dev/null || true)
          if printf '%s\n' "$sxml" | grep -q "snapshot='internal'"; then
            echo "snapshot '$sname' is internal — revert it with virsh snapshot-revert instead" >&2
            exit 1
          fi
          if [ "$i" -eq "$tidx" ]; then
            tmem=$(printf '%s\n' "$sxml" | xmlstarlet sel -t -v "/domainsnapshot/memory/@file" 2>/dev/null || true)
          fi
        done

        ${revertDataReview}

        echo "Reverting '$dom' to snapshot '$target' (the disk state at its creation)."
        echo "This DISCARDS all changes made after '$target' was taken."
        if [ "$tidx" -gt 0 ]; then
          echo "These newer snapshot(s) will be DELETED:"
          for ((i = 0; i < tidx; i++)); do
            echo "  ''${chain_path[i]}"
          done
        fi
        if [ -n "$tmem" ]; then
          echo "note: '$target' also saved RAM state ($tmem) — this disk-only revert boots fresh; use virsh snapshot-revert to resume that RAM state instead."
        fi
        echo
        confirm "Proceed and revert to '$target'?"

        ${revertCarry}

        discard() {
          [ -f "$1" ] || return 0
          rm -f "$1"
          echo "$dom: removed discarded overlay $1"
        }

        for ((i = 0; i < tidx; i++)); do
          child="''${chain_path[i]}"
          childxml=$(virsh snapshot-dumpxml "$dom" "$child")
          mapfile -t crows < <(printf '%s\n' "$childxml" \
            | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
                -v @name -o "|" -v "source/@file" -n)
          for row in "''${crows[@]}"; do
            f="''${row#*|}"
            [ -n "$f" ] || continue
            discard "$f"
          done
          cmem=$(printf '%s\n' "$childxml" | xmlstarlet sel -t -v "/domainsnapshot/memory/@file" 2>/dev/null || true)
          if [ -n "$cmem" ] && [ -f "$cmem" ]; then
            rm -f "$cmem"
            echo "$dom: removed memory state file $cmem"
          fi
          virsh snapshot-delete "$dom" "$child" --metadata
          echo "$dom: deleted newer snapshot '$child'"
        done

        snapxml=$(virsh snapshot-dumpxml "$dom" "$target")
        mapfile -t trows < <(printf '%s\n' "$snapxml" \
          | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
              -v @name -o "|" -v "source/@file" -n)
        for row in "''${trows[@]}"; do
          tdev="''${row%%|*}"
          overlay="''${row#*|}"
          [ -n "$tdev" ] && [ -n "$overlay" ] || continue
          base=$(printf '%s\n' "$snapxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev']" -v "source/@file" -n)
          devtype=$(printf '%s\n' "$snapxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev']" -v "@device" -n)
          if [ -z "$base" ]; then
            echo "  [$tdev] SKIP — no pre-snapshot source recorded"
            continue
          fi
          if [ "$devtype" = "disk" ] && [ "$overlay" != "$base" ]; then
            discard "$overlay"
            if [ -f "$overlay.carry" ]; then
              mv "$overlay.carry" "$overlay"
              echo "$dom: $tdev fresh overlay $overlay with the carried changes (backed by $base)"
            else
              qemu-img create -f qcow2 -b "$base" -F qcow2 "$overlay" >/dev/null
              echo "$dom: $tdev fresh overlay $overlay (backed by $base)"
            fi
            repoint_disk "$tdev" "$overlay"
          else
            [ "$overlay" != "$base" ] && discard "$overlay"
            repoint_disk "$tdev" "$base"
          fi
        done

        echo "$dom: reverted to '$target' — start the VM to boot that state."
        exit 0
      fi

      rotname=""
      newname=""
      rotate_note=""
      if [ "$sub" = "rotate" ]; then
        if [ "$all" -eq 1 ] || [ -n "$to" ]; then
          echo "rotate takes a snapshot name argument; --all/--to do not apply" >&2
          exit 1
        fi
        rotname="''${pos[2]:-$cur}"
        newname="''${as_name:-$rotname}"
        to="$rotname"
        rotate_note=", then recreate snapshot '$newname'"
      fi

      levels=1
      if [ "$all" -eq 1 ]; then
        levels="''${#chain_path[@]}"
      elif [ -n "$to" ]; then
        levels=0
        i=0
        for s in "''${chain_path[@]}"; do
          i=$((i + 1))
          if [ "$s" = "$to" ]; then levels=$i; break; fi
        done
        if [ "$levels" -eq 0 ]; then
          if virsh snapshot-info "$dom" "$to" >/dev/null 2>&1; then
            echo "snapshot '$to' exists but is not on the current chain (another branch?)" >&2
          else
            echo "no such snapshot: '$to'" >&2
          fi
          exit 1
        fi
      fi

      build_plan() {
        local snapxml row target overlay base devtype chain depth imm live
        cur=$(virsh snapshot-current --name "$dom" 2>/dev/null || true)
        if [ -z "$cur" ]; then return 1; fi
        snapxml=$(virsh snapshot-dumpxml "$dom" "$cur")
        if printf '%s\n' "$snapxml" | grep -q "snapshot='internal'"; then
          echo "snapshot '$cur' is internal — manage it with virsh (snapshot-revert / snapshot-delete) directly" >&2
          exit 1
        fi
        memfile=$(printf '%s\n' "$snapxml" | xmlstarlet sel -t -v "/domainsnapshot/memory/@file" 2>/dev/null || true)

        local -a rows
        mapfile -t rows < <(printf '%s\n' "$snapxml" \
          | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
              -v @name -o "|" -v "source/@file" -n)

        plan=()
        mismatch=0
        multilayer=0
        echo "Committing snapshot '$cur' of domain '$dom':"
        echo
        for row in "''${rows[@]}"; do
          target="''${row%%|*}"
          overlay="''${row#*|}"
          [ -n "$target" ] && [ -n "$overlay" ] || continue

          base=$(printf '%s\n' "$snapxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$target']" -v "source/@file" -n)
          devtype=$(printf '%s\n' "$snapxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$target']" -v "@device" -n)

          plan+=("$target|$overlay|$base|$devtype")

          if [ -z "$base" ]; then
            echo "  [$target] SKIP — no pre-snapshot source recorded"
            continue
          fi
          if [ "$devtype" != "disk" ] || [ "$overlay" = "$base" ]; then
            echo "  [$target] discard overlay (cdrom / no-op): $overlay"
            continue
          fi

          echo "  [$target] COMMIT  $overlay"
          echo "            INTO    $base"
          echo "            then delete the overlay and repoint the disk to the base."

          chain=$(qemu-img info --backing-chain -U "$overlay" 2>/dev/null \
                    | sed -n 's/^image: /              /p' || true)
          depth=$(printf '%s\n' "$chain" | grep -c . || true)
          depth=''${depth:-0}
          echo "            backing chain (depth $depth):"
          printf '%s\n' "$chain"
          if [ "$depth" -gt 2 ]; then
            multilayer=1
          fi

          live=$(virsh domblklist "$dom" 2>/dev/null | awk -v t="$target" '$1 == t { print $2 }')
          if [ -n "$live" ] && [ "$live" != "$overlay" ]; then
            mismatch=1
            echo "            !! DANGER: the domain's live disk for $target is"
            echo "            !!   $live"
            echo "            !! not this snapshot's overlay — layer(s) sit ABOVE this"
            echo "            !! snapshot and committing it would corrupt them."
          fi
          imm=$(qemu-img info -U "$overlay" 2>/dev/null | sed -n 's/^backing file: //p' || true)
          if [ -n "$imm" ] && [ "$imm" != "$base" ]; then
            mismatch=1
            echo "            !! DANGER: overlay's actual backing is"
            echo "            !!   $imm"
            echo "            !! but the snapshot's recorded base is"
            echo "            !!   $base"
          fi
          echo
        done
        return 0
      }

      execute_plan() {
        local row target overlay base devtype bak
        local -a backups=()
        for row in "''${plan[@]}"; do
          IFS="|" read -r target overlay base devtype <<<"$row"
          [ "$devtype" = "disk" ] || continue
          { [ -n "$base" ] && [ -f "$overlay" ] && [ "$overlay" != "$base" ]; } || continue
          bak="$base.precommit"
          if [ -e "$bak" ]; then
            echo "ABORT: $bak already exists — a previous commit may have been interrupted." >&2
            echo "       Restore: sudo mv $bak $base   — or remove it before retrying." >&2
            exit 1
          fi
          if cp --reflink=always "$base" "$bak" 2>/dev/null; then
            backups+=("$bak")
            echo "safety: reflinked $base -> $bak"
          else
            echo "WARNING: no reflink support for $base — proceeding WITHOUT a crash-safety copy for $target." >&2
          fi
        done
        sync

        restore_hint() {
          [ ''${#backups[@]} -gt 0 ] || return 0
          local b
          echo "" >&2
          echo "commit did NOT complete — pre-commit safety copies kept:" >&2
          for b in "''${backups[@]}"; do echo "  $b" >&2; done
          echo "restore a base with:  sudo mv <copy> <its-base>   (the overlay is still present)" >&2
        }
        trap restore_hint ERR

        if [ "$live" -eq 1 ]; then
          local -a commit_rows=()
          for row in "''${plan[@]}"; do
            IFS="|" read -r target overlay base devtype <<<"$row"
            [ -n "$target" ] && [ -n "$base" ] || continue
            [ -f "$overlay" ] && [ "$overlay" != "$base" ] || continue
            if [ "$devtype" = "disk" ] && qemu-img info -U "$overlay" | grep -q "^backing file:"; then
              commit_rows+=("$row")
            fi
          done

          local arow
          for row in "''${commit_rows[@]}"; do
            IFS="|" read -r target overlay base devtype <<<"$row"
            echo "$dom: live blockcommit $target  $overlay -> $base"
            if ! virsh blockcommit "$dom" "$target" --active --wait --verbose; then
              for arow in "''${commit_rows[@]}"; do
                IFS="|" read -r target overlay base devtype <<<"$arow"
                virsh blockjob "$dom" "$target" --abort >/dev/null 2>&1 || true
              done
              echo "$dom: blockcommit failed; all block jobs aborted, chain unchanged" >&2
              exit 1
            fi
          done

          for row in "''${commit_rows[@]}"; do
            IFS="|" read -r target overlay base devtype <<<"$row"
            ovsize=$(vsize "$overlay")
            basesize=$(vsize "$base")
            if [ -n "$ovsize" ] && [ -n "$basesize" ] && [ "$ovsize" -lt "$basesize" ]; then
              echo "$dom: $target was shrunk in its overlay, but a live commit keeps the base's larger size;" >&2
              echo "  run nixvirt-resize $dom with the shrunk size again while the VM is off" >&2
            fi
            if ! virsh blockjob "$dom" "$target" --pivot; then
              echo "$dom: pivot failed for $target — the job is still synchronized; retry 'virsh blockjob $dom $target --pivot' or cancel with --abort" >&2
              exit 1
            fi
            rm -f "$overlay"
            echo "$dom: $target source -> $base"
            repoint_disk "$target" "$base"
          done

          for row in "''${plan[@]}"; do
            IFS="|" read -r target overlay base devtype <<<"$row"
            [ -n "$target" ] && [ -n "$base" ] || continue
            [ -f "$overlay" ] && [ "$overlay" != "$base" ] || continue
            if [ "$devtype" = "disk" ] && qemu-img info -U "$overlay" 2>/dev/null | grep -q "^backing file:"; then
              continue
            fi
            echo "$dom: leaving $target overlay in place (in use by the running VM): $overlay"
            repoint_disk "$target" "$base"
          done
        else
          for row in "''${plan[@]}"; do
            IFS="|" read -r target overlay base devtype <<<"$row"
            [ -n "$target" ] && [ -n "$base" ] || continue

            if [ -f "$overlay" ] && [ "$overlay" != "$base" ]; then
              if [ "$devtype" = "disk" ] && qemu-img info -U "$overlay" | grep -q "^backing file:"; then
                echo "$dom: committing $target  $overlay -> $base"
                ovsize=$(vsize "$overlay")
                qemu-img commit "$overlay"
                basesize=$(vsize "$base")
                # qemu-img commit grows a smaller base but never shrinks a larger one, so a shrink made in the overlay is finished here.
                if [ -n "$ovsize" ] && [ -n "$basesize" ] && [ "$ovsize" -lt "$basesize" ]; then
                  qemu-img resize -q --shrink "$base" "$ovsize"
                  echo "$dom: shrank $base to the committed size"
                fi
                rm -f "$overlay"
              else
                echo "$dom: discarding $target overlay (cdrom/no backing): $overlay"
                rm -f "$overlay"
              fi
            fi

            echo "$dom: $target source -> $base"
            repoint_disk "$target" "$base"
          done
        fi

        virsh snapshot-delete "$dom" "$cur" --metadata
        if [ -n "$memfile" ] && [ -f "$memfile" ]; then
          rm -f "$memfile"
          echo "$dom: removed memory state file $memfile"
        fi

        trap - ERR
        for bak in "''${backups[@]}"; do
          rm -f "$bak" && echo "cleaned safety copy: $bak"
        done

        echo "$dom: committed and removed snapshot '$cur'"
      }

      if [ "$sub" = "delete" ]; then
        if [ "$all" -eq 1 ] || [ -n "$to" ]; then
          echo "delete takes a snapshot name argument; --all/--to do not apply" >&2
          exit 1
        fi
        dtarget="''${pos[2]:-$cur}"
        dxml=$(virsh snapshot-dumpxml "$dom" "$dtarget" 2>/dev/null || true)
        if [ -z "$dxml" ]; then
          echo "no such snapshot: '$dtarget'" >&2
          exit 1
        fi

        if printf '%s\n' "$dxml" | grep -q "snapshot='internal'"; then
          echo "Deleting INTERNAL snapshot '$dtarget' of '$dom' (record removed from the qcow2; current data is kept)."
          confirm "Proceed?"
          virsh snapshot-delete "$dom" "$dtarget"
          echo "$dom: deleted internal snapshot '$dtarget'"
          exit 0
        fi

        didx=-1
        i=0
        for s in "''${chain_path[@]}"; do
          if [ "$s" = "$dtarget" ]; then didx=$i; break; fi
          i=$((i + 1))
        done
        if [ "$didx" -lt 0 ]; then
          echo "snapshot '$dtarget' exists but is not on the current chain (another branch?) — not supported" >&2
          exit 1
        fi

        if [ "$didx" -eq 0 ]; then
          if [ "$live" -eq 1 ]; then
            echo "domain '$dom' is running — using live blockcommit (QEMU merges internally, no downtime)."
            echo
          fi
          echo "Deleting '$dtarget' = committing its overlay into its base (current data is kept)."
          echo
          build_plan || exit 1
          if [ "$mismatch" -eq 1 ] && [ "$live" -eq 1 ]; then
            echo "ABORT: inconsistent chain — refusing to live-commit; shut the VM off to inspect." >&2
            exit 1
          fi
          if [ "$mismatch" -eq 1 ]; then
            echo "*** DANGER lines above indicate an inconsistent chain. Proceed only if certain. ***"
            echo
          fi
          confirm "Proceed and delete '$dtarget' (commit + remove)?"
          execute_plan
          exit 0
        fi

        if [ "$live" -eq 1 ]; then
          echo "deleting a mid-chain external snapshot requires the domain shut off" >&2
          exit 1
        fi
        child="''${chain_path[$((didx - 1))]}"
        childxml=$(virsh snapshot-dumpxml "$dom" "$child")
        if printf '%s\n' "$childxml" | grep -q "snapshot='internal'"; then
          echo "snapshot '$child' (above '$dtarget') is internal — mixed chains are not supported" >&2
          exit 1
        fi

        mapfile -t drows < <(printf '%s\n' "$dxml" \
          | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
              -v @name -o "|" -v "source/@file" -n)

        echo "Deleting mid-chain snapshot '$dtarget' of '$dom':"
        echo "its overlay merges DOWN into its base; '$child' is rebased and keeps its state."
        echo
        dplan=()
        for row in "''${drows[@]}"; do
          tdev="''${row%%|*}"
          ovS="''${row#*|}"
          [ -n "$tdev" ] && [ -n "$ovS" ] || continue
          P=$(printf '%s\n' "$dxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev']" -v "source/@file" -n)
          devtype=$(printf '%s\n' "$dxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev']" -v "@device" -n)
          if [ "$devtype" != "disk" ] || [ -z "$P" ] || [ "$ovS" = "$P" ]; then
            echo "  [$tdev] skip (cdrom / no-op)"
            continue
          fi
          ovC=$(printf '%s\n' "$childxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/disks/disk[@name='$tdev']" -v "source/@file" -n 2>/dev/null || true)
          if [ -z "$ovC" ]; then
            echo "  [$tdev] ABORT: child '$child' has no overlay for this disk — inconsistent chain" >&2
            exit 1
          fi
          cbase=$(printf '%s\n' "$childxml" | xmlstarlet sel -t \
            -m "/domainsnapshot/domain/devices/disk[target/@dev='$tdev']" -v "source/@file" -n)
          imm=$(qemu-img info -U "$ovC" 2>/dev/null | sed -n 's/^backing file: //p' || true)
          if [ "$cbase" != "$ovS" ] || { [ -n "$imm" ] && [ "$imm" != "$ovS" ]; }; then
            echo "  [$tdev] ABORT: chain metadata inconsistent (child records '$cbase', actual backing '$imm', expected '$ovS')" >&2
            exit 1
          fi
          echo "  [$tdev] COMMIT  $ovS"
          echo "            INTO    $P"
          echo "            REBASE  $ovC onto $P"
          dplan+=("$tdev|$ovS|$P|$ovC")
        done
        echo
        confirm "Proceed and delete '$dtarget' (merge down + rebase '$child')?"

        # shellcheck disable=SC2329
        dhint() {
          echo "" >&2
          echo "delete did NOT complete — any .precommit safety copies were kept; restore a base with: sudo mv <copy> <its-base>" >&2
        }
        trap dhint ERR

        for row in "''${dplan[@]}"; do
          IFS="|" read -r tdev ovS P ovC <<<"$row"
          bak="$P.precommit"
          if [ -e "$bak" ]; then
            echo "ABORT: $bak already exists — a previous commit may have been interrupted." >&2
            exit 1
          fi
          if cp --reflink=always "$P" "$bak" 2>/dev/null; then
            echo "safety: reflinked $P -> $bak"
          else
            echo "WARNING: no reflink support for $P — proceeding WITHOUT a crash-safety copy." >&2
          fi
        done
        sync

        for row in "''${dplan[@]}"; do
          IFS="|" read -r tdev ovS P ovC <<<"$row"
          pfmt=$(qemu-img info -U "$P" 2>/dev/null | sed -n 's/^file format: //p')
          echo "$dom: committing $tdev  $ovS -> $P"
          qemu-img commit "$ovS"
          echo "$dom: rebasing $tdev  $ovC onto $P"
          qemu-img rebase -u -b "$P" -F "''${pfmt:-qcow2}" "$ovC"
          rm -f "$ovS"
        done

        tmpf=$(mktemp)
        cxml="$childxml"
        for row in "''${dplan[@]}"; do
          IFS="|" read -r tdev ovS P ovC <<<"$row"
          cxml=$(printf '%s\n' "$cxml" | xmlstarlet ed -u "/domainsnapshot/domain/devices/disk[target/@dev='$tdev']/source/@file" -v "$P")
        done
        printf '%s\n' "$cxml" > "$tmpf"
        if [ "$child" = "$cur" ]; then
          virsh snapshot-create "$dom" "$tmpf" --redefine --current >/dev/null
        else
          virsh snapshot-create "$dom" "$tmpf" --redefine >/dev/null
        fi
        rm -f "$tmpf"

        dmem=$(printf '%s\n' "$dxml" | xmlstarlet sel -t -v "/domainsnapshot/memory/@file" 2>/dev/null || true)
        virsh snapshot-delete "$dom" "$dtarget" --metadata
        if [ -n "$dmem" ] && [ -f "$dmem" ]; then
          rm -f "$dmem"
          echo "$dom: removed memory state file $dmem"
        fi

        trap - ERR
        for row in "''${dplan[@]}"; do
          IFS="|" read -r tdev ovS P ovC <<<"$row"
          if [ -e "$P.precommit" ]; then
            rm -f "$P.precommit"
            echo "cleaned safety copy: $P.precommit"
          fi
        done
        echo "$dom: deleted snapshot '$dtarget' (data preserved in the chain)"
        exit 0
      fi

      if [ "$sub" = "rotate" ] && [ "$newname" != "$rotname" ]; then
        if virsh snapshot-info "$dom" "$newname" >/dev/null 2>&1; then
          collides=1
          for ((i = 0; i < levels; i++)); do
            if [ "''${chain_path[i]}" = "$newname" ]; then collides=0; break; fi
          done
          if [ "$collides" -eq 1 ]; then
            echo "rotate: snapshot '$newname' already exists — recreating under that name would collide" >&2
            exit 1
          fi
        fi
      fi

      if [ "$levels" -gt 1 ]; then
        echo "Will commit these $levels snapshot(s), top-down:"
        for ((i = 0; i < levels; i++)); do
          echo "  ''${chain_path[i]}"
        done
        if [ "$levels" -lt "''${#chain_path[@]}" ]; then
          echo "New current snapshot afterwards: ''${chain_path[levels]}"
        else
          echo "No snapshots will remain on this chain afterwards."
        fi
        echo
        confirm "Proceed and commit $levels level(s) of '$dom'$rotate_note?"
        rounds=0
        while [ "$rounds" -lt "$levels" ]; do
          if ! build_plan; then
            echo "ABORT: no current snapshot left after $rounds round(s)" >&2
            exit 1
          fi
          expected="''${chain_path[rounds]}"
          if [ "$cur" != "$expected" ]; then
            echo "ABORT: expected current snapshot '$expected' but found '$cur'" >&2
            exit 1
          fi
          if [ "$mismatch" -eq 1 ]; then
            echo "ABORT at '$cur': chain/metadata inconsistency — fix manually before continuing." >&2
            exit 1
          fi
          execute_plan
          rounds=$((rounds + 1))
          echo
        done
        remaining=$(virsh snapshot-list "$dom" --name 2>/dev/null | grep -c . || true)
        if [ "''${remaining:-0}" -gt 0 ]; then
          echo "$dom: committed $rounds level(s); $remaining snapshot(s) remain."
        else
          echo "$dom: committed $rounds level(s); no snapshots remain."
        fi
      else
        build_plan
        if [ "$multilayer" -eq 1 ]; then
          echo "*** MULTI-LAYER chain: this commits only the CURRENT (top) snapshot."
          echo "*** Use --all (whole chain) or --to <snapshot> (down to a chosen one)."
          echo
        fi
        if [ "$mismatch" -eq 1 ] && [ "$live" -eq 1 ]; then
          echo "ABORT: inconsistent chain — refusing to live-commit; shut the VM off to inspect." >&2
          echo "(an interrupted live commit can cause this — check 'nixvirt-snapshot list $dom' for stale metadata)" >&2
          exit 1
        fi
        if [ "$mismatch" -eq 1 ]; then
          echo "*** DANGER lines above indicate an inconsistent chain. Proceed only if certain. ***"
          echo
        fi
        confirm "Proceed and commit+delete the above overlay(s)$rotate_note?"
        execute_plan
      fi

      if [ "$sub" = "rotate" ]; then
        echo
        echo "$dom: recreating snapshot '$newname'"
        virsh snapshot-create-as "$dom" "$newname" --disk-only --atomic
        echo "Snapshot chain is now:"
        virsh snapshot-list "$dom" --tree 2>/dev/null | sed '/^$/d; s/^/  /'
      fi
    '';
  };

  nixvirtMount = pkgs.writeShellApplication {
    name = "nixvirt-mount";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.qemu
      pkgs.util-linux
      pkgs.kmod
      pkgs.ntfs3g
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.libguestfs
    ];
    text = ''
      base_root=/run/nixvirt-mounts
      export LIBVIRT_DEFAULT_URI=qemu:///system

      action=mount
      rw=0
      pos=()
      for a in "$@"; do
        case "$a" in
          -u|--umount|--unmount) action=umount ;;
          -w|--rw|--write|--read-write) rw=1 ;;
          -h|--help)
            echo "usage: nixvirt-mount [-u] [-w] <domain>"
            echo "  mounts a SHUT-OFF domain's disks under $base_root/<domain>"
            echo "  (read-only by default)"
            echo "  -w   mount READ-WRITE (writes into the image; VM must stay off)"
            echo "  -u   unmount and detach"
            exit 0 ;;
          *) pos+=("$a") ;;
        esac
      done
      dom="''${pos[0]:-}"
      [ -n "$dom" ] || { echo "usage: nixvirt-mount [-u] [-w] <domain>" >&2; exit 1; }

      if [ "$(id -u)" -ne 0 ]; then echo "run as root: sudo nixvirt-mount [-u] [-w] $dom" >&2; exit 1; fi

      base="$base_root/$dom"
      owner_uid=''${SUDO_UID:-0}
      owner_gid=''${SUDO_GID:-0}

      mkdir -p "$base_root"
      exec 9>"$base_root/.$dom.lock"
      if ! flock -n 9; then
        echo "another nixvirt-mount is already running for '$dom'; refusing to run concurrently." >&2
        exit 1
      fi

      if [ "$action" = umount ]; then
        [ -d "$base" ] || { echo "$dom: not mounted"; exit 0; }
        mounts=$(findmnt -rno TARGET 2>/dev/null | grep -F "$base/" | sort -r || true)
        if [ -n "$mounts" ]; then
          while read -r mp; do
            [ -n "$mp" ] || continue
            if umount "$mp" 2>/dev/null; then echo "  umounted $mp"
            else echo "  BUSY: $mp (cd out of it / close file managers)" >&2; fi
          done <<< "$mounts"
        fi
        if findmnt -rno TARGET 2>/dev/null | grep -qF "$base/"; then
          echo "$dom: some mounts still busy; left $base in place" >&2
          exit 1
        fi
        # A guestmount daemon writes back after its unmount, so the image is only free once it exits.
        for pidf in "$base"/.*.pid; do
          [ -f "$pidf" ] || continue
          pid=$(cat "$pidf")
          for _ in $(seq 1 600); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
          done
        done
        if [ -f "$base/.nbd" ]; then
          while read -r dev; do
            [ -n "$dev" ] || continue
            qemu-nbd --disconnect "$dev" >/dev/null 2>&1 && echo "  detached $dev"
          done < "$base/.nbd"
        fi
        rm -rf "$base"
        echo "$dom: unmounted and detached"
        exit 0
      fi

      state=$(virsh domstate "$dom" 2>/dev/null || true)
      [ -n "$state" ] || { echo "$dom: no such domain" >&2; exit 1; }
      if [ "$state" != "shut off" ]; then
        echo "$dom must be shut off to mount its disks read-only (state: $state)" >&2
        exit 1
      fi

      while read -r src; do
        [ -n "$src" ] || continue
        while read -r other; do
          [ -n "$other" ] && [ "$other" != "$dom" ] || continue
          if virsh domblklist "$other" 2>/dev/null | awk '{print $2}' | grep -qxF "$src"; then
            ostate=$(virsh domstate "$other" 2>/dev/null || true)
            case "$ostate" in
              running|paused)
                echo "domain '$other' ($ostate) uses the same disk image: $src" >&2
                echo "shut it down before mounting '$dom'" >&2
                exit 1
                ;;
            esac
          fi
        done < <(virsh list --all --name)
      done < <(virsh domblklist "$dom" --details 2>/dev/null | tail -n +3 | awk '$1=="file" && $2=="disk" {print $4}')
      if [ -d "$base" ] && findmnt -rno TARGET 2>/dev/null | grep -qF "$base/"; then
        echo "$dom already mounted under $base — run: sudo nixvirt-mount -u $dom" >&2
        exit 1
      fi

      if [ "$rw" -eq 1 ]; then
        echo "!! READ-WRITE mode: changes are written into $dom's disk image."
        echo "!! Keep the VM OFF the entire time. A dirty/hibernated NTFS will"
        echo "!! mount read-only (boot the VM once and shut down cleanly to clear)."
        echo
      fi

      untrusted=0
      untrusted_domains=(${lib.escapeShellArgs cfg.untrusted})
      for u in "''${untrusted_domains[@]}"; do
        if [ "$u" = "$dom" ]; then untrusted=1; fi
      done
      if [ "$untrusted" -eq 0 ]; then
        modprobe nbd max_part=16 2>/dev/null || true
        [ -e /dev/nbd0 ] || { echo "nbd kernel module unavailable" >&2; exit 1; }
      fi

      mkdir -p "$base"
      : > "$base/.nbd"

      find_free_nbd() {
        local n
        for n in /sys/block/nbd*; do
          [ -e "$n/size" ] || continue
          if [ "$(cat "$n/size" 2>/dev/null || echo 0)" = "0" ]; then
            echo "/dev/$(basename "$n")"; return 0
          fi
        done
        return 1
      }

      mounted_any=0
      while read -r ttype device target source; do
        [ "$device" = "disk" ] || continue
        [ "$ttype" = "file" ] || continue
        [ -n "$source" ] && [ "$source" != "-" ] && [ -f "$source" ] || continue

        if [ "$untrusted" -eq 1 ]; then
          # The libguestfs appliance parses the guest's filesystems in its own kernel, so a crafted one has to escape a VM
          # rather than exploit a host driver. The appliance gets no network.
          mp="$base/$target"
          mkdir -p "$mp"
          fmt=$(qemu-img info -U "$source" 2>/dev/null | sed -n 's/^file format: //p')
          gm_opts=(--ro)
          if [ "$rw" -eq 1 ]; then gm_opts=(); fi
          ok=0
          for how in -i /dev/sda1 /dev/sda; do
            sel=(-i)
            if [ "$how" != "-i" ]; then sel=(-m "$how"); fi
            if unshare --net -- env -i PATH="$PATH" HOME=/root TMPDIR=/tmp LIBGUESTFS_BACKEND=direct \
                LIBGUESTFS_PATH=${pkgs.libguestfs-appliance} \
                guestmount "''${gm_opts[@]}" --format="''${fmt:-raw}" -a "$source" "''${sel[@]}" -o allow_other \
                --pid-file "$base/.$target.pid" "$mp" 9>&- 2>/dev/null; then
              ok=1
              break
            fi
          done
          if [ "$ok" -eq 1 ]; then
            what="$how"
            if [ "$how" = "-i" ]; then what="the guest's own filesystem layout"; fi
            echo "$target ($source) -> $mp  (through the libguestfs appliance: $what)"
            mounted_any=1
          else
            rmdir "$mp" 2>/dev/null || true
            echo "$target ($source): no mountable filesystem; skipped" >&2
          fi
          continue
        fi

        dev=$(find_free_nbd) || { echo "no free nbd device" >&2; continue; }
        nbd_opts=(--read-only)
        if [ "$rw" -eq 1 ]; then nbd_opts=(); fi
        if ! qemu-nbd "''${nbd_opts[@]}" --connect="$dev" "$source" 9>&-; then
          echo "  failed to attach $source" >&2; continue
        fi
        echo "$dev" >> "$base/.nbd"
        partx -u "$dev" 2>/dev/null || true

        parts=""
        for _ in 1 2 3 4 5; do
          parts=$(lsblk -rno NAME "$dev" 2>/dev/null | tail -n +2)
          [ -n "$parts" ] && break
          sleep 0.5
        done
        [ -n "$parts" ] || parts=$(basename "$dev")

        echo "$target ($source) -> $dev:"
        while read -r p; do
          [ -n "$p" ] || continue
          pdev="/dev/$p"
          fstype=$(blkid -o value -s TYPE "$pdev" 2>/dev/null || true)
          [ -n "$fstype" ] || continue
          label=$(blkid -o value -s LABEL "$pdev" 2>/dev/null || true)
          mp="$base/$target/$p"
          mkdir -p "$mp"
          hard="nosuid,nodev,noexec"
          if [ "$rw" -eq 1 ]; then mopt="rw,$hard"; ntopt="rw,$hard"; else mopt="ro,$hard"; ntopt="ro,ignore_hibernation,$hard"; fi
          own=""
          case "$fstype" in
            ntfs|vfat|exfat|msdos) own=",uid=$owner_uid,gid=$owner_gid,umask=022" ;;
          esac
          if { [ "$fstype" = ntfs ] && [ "$rw" -eq 1 ] && mount -t ntfs-3g -o "$ntopt$own" "$pdev" "$mp" 2>/dev/null 9>&-; } \
             || mount -o "$mopt$own" "$pdev" "$mp" 2>/dev/null \
             || { [ "$fstype" = ntfs ] && mount -t ntfs-3g -o "$ntopt$own" "$pdev" "$mp" 2>/dev/null 9>&-; }; then
            note=""
            if [ "$rw" -eq 1 ]; then
              cur_opts=$(findmnt -rno OPTIONS "$mp" 2>/dev/null || true)
              case ",$cur_opts," in
                *,ro,*) note="  !! mounted READ-ONLY (volume dirty/hibernated)" ;;
              esac
            fi
            echo "  $pdev  $fstype''${label:+ [$label]}  ->  $mp$note"
            mounted_any=1
          else
            rmdir "$mp" 2>/dev/null || true
            echo "  $pdev  $fstype  (could not mount; skipped)" >&2
          fi
        done <<< "$parts"
      done < <(virsh domblklist "$dom" --details 2>/dev/null | tail -n +3)

      if [ "$mounted_any" -ne 1 ]; then
        echo "$dom: nothing mountable; cleaning up" >&2
        while read -r d; do
          [ -n "$d" ] || continue
          qemu-nbd --disconnect "$d" >/dev/null 2>&1 || true
        done < "$base/.nbd"
        rm -rf "$base"
        exit 1
      fi

      echo
      if [ "$rw" -eq 1 ]; then
        echo "$dom mounted READ-WRITE under: $base  (keep the VM OFF!)"
      else
        echo "$dom mounted READ-ONLY under: $base"
      fi
      echo "done:  sudo nixvirt-mount -u $dom"
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

  options.my.virtualisation.nixvirt = {
    enable = mkEnableOption "declarative libvirt domain management via NixVirt";

    domains = mkOption {
      type = listOf domainOpt;
      default = [ ];
      description = "Domains to define declaratively at qemu:///system.";
    };

    reapNvram = mkOption {
      type = bool;
      default = true;
      description = ''
        Delete orphaned UEFI NVRAM files under /var/lib/libvirt/qemu/nvram that no
        defined domain references. Runs after domains are redefined on each nixvirt
        service start. Turn off if you keep nvram for domains managed outside NixVirt.
      '';
    };

    dataDisks = mkOption {
      type = attrsOf (submodule {
        options = {
          image = mkOption {
            type = str;
            description = ''
              Raw image attached to the domain with snapshot="no", so snapshots and reverts never touch it.
              The disk element is added to the domain definition at build time and the image is created sparse when missing.
              Revisions are reflink copies next to it, so it must sit on btrfs or XFS.
            '';
          };
          bus = mkOption {
            type = enum [
              "scsi"
              "sata"
              "virtio"
            ];
            default = "scsi";
            description = "Bus the data disk is attached to. The first free sdX or vdX target name is used.";
          };
          serial = mkOption {
            type = nullOr str;
            default = null;
            description = "Serial number the guest sees.";
          };
          vendor = mkOption {
            type = nullOr str;
            default = null;
            description = "Vendor the guest sees (scsi only, up to 8 characters).";
          };
          product = mkOption {
            type = nullOr str;
            default = null;
            description = "Product name the guest sees (scsi only, up to 16 characters).";
          };
          size = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              Virtual size (K, M, G or T suffix). Null follows the domain's system disk, so anything that fit there fits here:
              `nixvirt-resize` resizes both together, and a system disk grown some other way grows this one, partition and filesystem
              included, at the next nixvirt service start while the VM is off. Only `nixvirt-resize` ever shrinks it.
            '';
          };
          keep = mkOption {
            type = ints.positive;
            default = 3;
            description = "How many kept revisions to retain. Pinned revisions are not counted.";
          };
          hashPaths = mkOption {
            type = listOf str;
            default = [ ];
            description = "Folders on the data disk compared by content, which catches files rewritten with their size and date kept.";
          };
          sourcePaths = mkOption {
            type = listOf str;
            default = [ ];
            description = "Folders where edited scripts are normal work, so they are not listed under RUNS CODE.";
          };
          highlight = mkOption {
            type = attrsOf (listOf str);
            default = { };
            example = {
              "RUNS CODE" = [ "work/*.cfg" ];
              "CONFIG" = [ "*/settings.json" ];
            };
            description = ''
              Extra review sections, from a title to case-insensitive glob patterns relative to the data disk root (* also matches /).
              Patterns under "RUNS CODE" add to the built-in executable, script, git hook and editor task rules.
            '';
          };
          rescueRoot = mkOption {
            type = nullOr str;
            default = null;
            description = "Folder on the system disk that a revert scans for files it would lose, which can be copied to the data disk first.";
          };
          rescueExclude = mkOption {
            type = listOf str;
            default = [ ];
            description = "Glob patterns relative to rescueRoot that the revert scan skips.";
          };
          windows = {
            letter = mkOption {
              type = nullOr str;
              default = null;
              description = "Drive letter `nixvirt-data link` pins the data disk to. A CD drive holding it moves to a free letter.";
            };
            carry = mkOption {
              type = attrsOf str;
              default = { };
              example = {
                "Users/me/Documents/Work" = "Work";
              };
              description = ''
                System disk path to data disk path. `nixvirt-data carry` copies them over with their Windows permissions,
                and after a revert `nixvirt-data link` deletes the system disk copies and puts junctions where folders were.
              '';
            };
            userEnv = mkOption {
              type = attrsOf (attrsOf str);
              default = { };
              description = "Per profile folder under Users, environment variables `nixvirt-data link` writes into that user's registry hive.";
            };
          };
          linux = {
            mountPoint = mkOption {
              type = str;
              default = "/mnt/data";
              description = "Where `nixvirt-data link` mounts the data disk in a Linux guest, through a marked block in its /etc/fstab.";
            };
            carry = mkOption {
              type = attrsOf str;
              default = { };
              example = {
                "home/me/work" = "work";
              };
              description = ''
                Path relative to the guest's root to data disk path, for a Linux guest, which formats the data disk as ext4.
                `nixvirt-data carry` copies them with their owners, modes and ACLs, and after a revert `nixvirt-data link`
                replaces carried folders with symlinks into the mount point. A carried file is only removed from the system disk,
                because programs that save by renaming would replace a link. Point them at the data disk with userEnv.
              '';
            };
            userEnv = mkOption {
              type = attrsOf (attrsOf str);
              default = { };
              description = "Per guest user, environment variables `nixvirt-data link` writes to ~/.config/environment.d, which systemd user sessions read.";
            };
          };
        };
      });
      default = { };
      description = ''
        Persistent data disks with reviewed revisions, keyed by domain name. A revert of such a domain first reviews
        what changed on the data disk since the last kept revision, then keeps or discards it.
      '';
    };

    untrusted = mkOption {
      type = listOf str;
      default = [ ];
      example = [ "malware-lab" ];
      description = ''
        Domains whose guests may be hostile. `nixvirt-mount` opens their disks with guestmount through the libguestfs
        appliance instead of the host kernel's filesystem drivers, so a crafted filesystem has to escape a VM.
      '';
    };

    carryOnRevert = mkOption {
      type = attrsOf (submodule {
        options = {
          paths = mkOption {
            type = listOf str;
            example = [ "Users/me/AppData/Roaming/Tool/config" ];
            description = ''
              Folders and files on the system disk, relative to the root of the filesystem holding them. After the revert is
              confirmed, their changes since the snapshot are reviewed, and the chosen ones, deletions included, are copied
              into the fresh snapshot layer with their permissions. This suits small folders, and large ones belong on a data disk.
            '';
          };
          hashPaths = mkOption {
            type = listOf str;
            default = [ ];
            description = "Paths among them compared by content, which catches files rewritten with their size and date kept.";
          };
          sourcePaths = mkOption {
            type = listOf str;
            default = [ ];
            description = "Paths among them where edited scripts are normal work, so they are not listed under RUNS CODE.";
          };
          highlight = mkOption {
            type = attrsOf (listOf str);
            default = { };
            description = "Extra review sections, from a title to case-insensitive glob patterns relative to the filesystem root.";
          };
        };
      });
      default = { };
      description = ''
        Per domain, paths whose changes a revert can carry into the fresh layer after a review, instead of losing them.
        Unlike a data disk, the copy happens on every revert until a rotate keeps it in the base.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      nixvirtSnapshot
      nixvirtMount
      nixvirtData
      nixvirtResize
    ];

    assertions = lib.flatten (
      lib.mapAttrsToList (n: dd: [
        {
          assertion = builtins.elem n (map (d: domainName d.definition) cfg.domains);
          message = "my.virtualisation.nixvirt.dataDisks.${n}: no domain in my.virtualisation.nixvirt.domains is named ${n}";
        }
        {
          assertion = dd.bus == "scsi" || (dd.vendor == null && dd.product == null);
          message = "my.virtualisation.nixvirt.dataDisks.${n}: vendor and product only apply to the scsi bus";
        }
        {
          # xmlstarlet reads & in values as the start of an entity.
          assertion = lib.all (v: v == null || builtins.match ''.*[&<>"].*'' v == null) [
            dd.image
            dd.serial
            dd.vendor
            dd.product
          ];
          message = "my.virtualisation.nixvirt.dataDisks.${n}: image, serial, vendor and product cannot contain & < > or \"";
        }
        {
          assertion = dd.windows.letter == null || builtins.match "[D-Z]" dd.windows.letter != null;
          message = "my.virtualisation.nixvirt.dataDisks.${n}.windows.letter must be one upper case letter from D to Z";
        }
        {
          assertion = dd.windows.carry == { } || dd.linux.carry == { };
          message = "my.virtualisation.nixvirt.dataDisks.${n}: a data disk serves one system, so set windows.carry or linux.carry";
        }
        {
          assertion = builtins.match "/[^[:space:]]*[^/[:space:]]" dd.linux.mountPoint != null;
          message = "my.virtualisation.nixvirt.dataDisks.${n}.linux.mountPoint must be an absolute path without spaces";
        }
        {
          assertion = lib.all relativePath (lib.attrNames dd.linux.carry ++ lib.attrValues dd.linux.carry);
          message = "my.virtualisation.nixvirt.dataDisks.${n}.linux.carry paths must be relative, without . or .. components";
        }
        {
          assertion = lib.all relativePath (
            lib.attrNames dd.windows.carry ++ lib.attrValues dd.windows.carry
          );
          message = "my.virtualisation.nixvirt.dataDisks.${n}.windows.carry paths must be relative, without . or .. components";
        }
      ]) cfg.dataDisks
      ++ lib.mapAttrsToList (n: c: [
        {
          assertion = builtins.elem n (map (d: domainName d.definition) cfg.domains);
          message = "my.virtualisation.nixvirt.carryOnRevert.${n}: no domain in my.virtualisation.nixvirt.domains is named ${n}";
        }
        {
          assertion = c.paths != [ ] && lib.all relativePath c.paths;
          message = "my.virtualisation.nixvirt.carryOnRevert.${n}.paths must be relative, without . or .. components";
        }
        {
          assertion = lib.all (p: lib.all (q: p == q || !lib.hasPrefix "${q}/" p) c.paths) c.paths;
          message = "my.virtualisation.nixvirt.carryOnRevert.${n}.paths must not contain one another";
        }
      ]) cfg.carryOnRevert
      ++ map (n: {
        assertion = builtins.elem n (map (d: domainName d.definition) cfg.domains);
        message = "my.virtualisation.nixvirt.untrusted: no domain in my.virtualisation.nixvirt.domains is named ${n}";
      }) cfg.untrusted
    );

    virtualisation.libvirt = {
      enable = true;
      swtpm.enable = true;
      connections."qemu:///system".domains = domains;
    };

    users.users.${dataUser} = {
      isSystemUser = true;
      group = dataUser;
      extraGroups = [ "kvm" ];
      description = "Runs the libguestfs appliance that reads and resizes guest disks";
    };
    users.groups.${dataUser} = { };

    systemd.services.nixvirt = {
      restartTriggers = map (d: d.definition) domains;
      serviceConfig.ExecStartPre = mkIf hasData "${getExe nixvirtData} init --all";
      serviceConfig.ExecStartPost = getExe snapshotFixup;
    };
  };
}
