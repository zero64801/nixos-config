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

  snapshotFixup = pkgs.writeShellApplication {
    name = "nixvirt-snapshot-fixup";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.virt-manager
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

  snapshotFlatten = pkgs.writeShellApplication {
    name = "nixvirt-snapshot-flatten";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.virt-manager
      pkgs.qemu
      pkgs.xmlstarlet
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      export LIBVIRT_DEFAULT_URI=qemu:///system

      assume_yes=0
      pos=()
      for a in "$@"; do
        case "$a" in
          -y|--yes) assume_yes=1 ;;
          *) pos+=("$a") ;;
        esac
      done
      dom="''${pos[0]:-}"
      [ -n "$dom" ] || { echo "usage: nixvirt-snapshot-flatten [-y] <domain>" >&2; exit 1; }

      if [ "$(id -u)" -ne 0 ]; then echo "run as root: sudo nixvirt-snapshot-flatten $dom" >&2; exit 1; fi

      state=$(virsh domstate "$dom" 2>/dev/null || true)
      if [ "$state" != "shut off" ]; then
        echo "domain '$dom' must be shut off (state: ''${state:-unknown})" >&2
        exit 1
      fi

      cur=$(virsh snapshot-current --name "$dom" 2>/dev/null || true)
      if [ -z "$cur" ]; then
        echo "$dom has no current snapshot — nothing to flatten" >&2
        exit 0
      fi

      snapxml=$(virsh snapshot-dumpxml "$dom" "$cur")

      mapfile -t rows < <(printf '%s\n' "$snapxml" \
        | xmlstarlet sel -t -m "/domainsnapshot/disks/disk[@snapshot='external']" \
            -v @name -o "|" -v "source/@file" -n)

      plan=()
      warn=0
      echo "About to flatten snapshot '$cur' of domain '$dom':"
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
          warn=1
          echo "            !! WARNING: MULTI-LAYER chain — flattening only this"
          echo "            !! layer can corrupt the layer(s) sitting above it."
        fi
        imm=$(qemu-img info -U "$overlay" 2>/dev/null | sed -n 's/^backing file: //p' || true)
        if [ -n "$imm" ] && [ "$imm" != "$base" ]; then
          warn=1
          echo "            !! WARNING: overlay's actual backing is"
          echo "            !!   $imm"
          echo "            !! but the snapshot's recorded base is"
          echo "            !!   $base"
        fi
        echo
      done

      if [ "$warn" -eq 1 ]; then
        echo "*** This is NOT a simple single-snapshot chain. Proceed only if certain. ***"
        echo
      fi

      if [ "$assume_yes" -ne 1 ]; then
        if [ ! -e /dev/tty ]; then
          echo "non-interactive (no tty) and no -y/--yes given; aborting." >&2
          exit 1
        fi
        printf 'Proceed and commit+delete the above overlays? [y/N] '
        read -r reply </dev/tty || reply=""
        case "$reply" in
          y|Y|yes|YES) ;;
          *) echo "aborted; nothing was changed."; exit 0 ;;
        esac
      fi

      backups=()
      for row in "''${plan[@]}"; do
        IFS="|" read -r target overlay base devtype <<<"$row"
        [ "$devtype" = "disk" ] || continue
        { [ -n "$base" ] && [ -f "$overlay" ] && [ "$overlay" != "$base" ]; } || continue
        bak="$base.preflatten"
        if [ -e "$bak" ]; then
          echo "ABORT: $bak already exists — a previous flatten may have been interrupted." >&2
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
        echo "flatten did NOT complete — pre-commit safety copies kept:" >&2
        for b in "''${backups[@]}"; do echo "  $b" >&2; done
        echo "restore a base with:  sudo mv <copy> <its-base>   (the overlay is still present)" >&2
      }
      trap restore_hint ERR

      for row in "''${plan[@]}"; do
        IFS="|" read -r target overlay base devtype <<<"$row"
        [ -n "$target" ] && [ -n "$base" ] || continue

        if [ -f "$overlay" ] && [ "$overlay" != "$base" ]; then
          if [ "$devtype" = "disk" ] && qemu-img info -U "$overlay" | grep -q "^backing file:"; then
            echo "$dom: committing $target  $overlay -> $base"
            qemu-img commit "$overlay"
          else
            echo "$dom: discarding $target overlay (cdrom/no backing): $overlay"
          fi
          rm -f "$overlay"
        fi

        echo "$dom: $target source -> $base"
        virt-xml "$dom" --edit "target=$target" --disk "path=$base"
      done

      virsh snapshot-delete "$dom" "$cur" --metadata

      trap - ERR
      for bak in "''${backups[@]}"; do
        rm -f "$bak" && echo "cleaned safety copy: $bak"
      done

      echo "$dom: flattened and removed snapshot '$cur'"
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

      modprobe nbd max_part=16 2>/dev/null || true
      [ -e /dev/nbd0 ] || { echo "nbd kernel module unavailable" >&2; exit 1; }

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

  options.nyx.virtualisation.nixvirt = {
    enable = mkEnableOption "declarative libvirt domain management via NixVirt";

    domains = mkOption {
      type = listOf domainOpt;
      default = [ ];
      description = "Domains to define declaratively at qemu:///system.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ snapshotFlatten nixvirtMount ];

    virtualisation.libvirt = {
      enable = true;
      swtpm.enable = true;
      connections."qemu:///system".domains = cfg.domains;
    };

    systemd.services.nixvirt = {
      restartTriggers = map (d: d.definition) cfg.domains;
      serviceConfig.ExecStartPost = getExe snapshotFixup;
    };
  };
}
