# nix build --impure --no-link --expr 'import ./apps/confine/_tests/seccomp.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

let
  mkFilter = pkgs.callPackage ../_lib/seccomp.nix { };

  mkProbe =
    p: name:
    p.runCommandCC name { } ''
      mkdir -p "$out/bin"
      $CC -O2 -Wall -Wextra -Werror -o "$out/bin/probe" ${./seccomp-probe.c}
    '';

  probe = mkProbe pkgs "confine-seccomp-probe";
  # A real i386 binary, since the 32-bit ABI is the half of a multiarch filter that only a 32-bit program exercises.
  probe32 = mkProbe pkgs.pkgsi686Linux "confine-seccomp-probe32";

  variants = {
    none = null;
    strict = mkFilter { };
    nesting = mkFilter { nesting = true; };
    userns = mkFilter { userns = true; };
    devel = mkFilter { devel = true; };
    steam = mkFilter {
      nesting = true;
      multiarch = true;
      bluetooth = true;
    };
    can = mkFilter { can = true; };
    iouring = mkFilter { ioUring = true; };
  };

  probes64 = "keyctl userns clone3 tiocsti tioclinux open_tree setns personality modify_ldt socket_packet socket_inet socket_can ptrace io_uring chroot mount netfilter xtables xtables6 ip6_tclass";
  probes32 = "keyctl userns tiocsti ptrace modify_ldt socketcall_inet socketcall_packet";

  expected = ''
    none     64:keyctl            ok
    none     64:userns            ok
    none     64:clone3            EINVAL
    none     64:tiocsti           ENOTTY
    none     64:tioclinux         ENOTTY
    none     64:open_tree         ok
    none     64:setns             EBADF
    none     64:personality       ok
    none     64:modify_ldt        ok
    none     64:socket_packet     EPERM
    none     64:socket_inet       ok
    none     64:socket_can        ok
    none     64:ptrace            ok
    none     64:io_uring          EFAULT
    none     64:chroot            EFAULT
    none     64:mount             EFAULT
    none     64:netfilter         ok
    none     64:xtables           EBADF
    none     64:xtables6          EBADF
    none     64:ip6_tclass        EBADF
    strict   64:keyctl            EPERM
    strict   64:userns            EPERM
    strict   64:clone3            ENOSYS
    strict   64:tiocsti           EPERM
    strict   64:tioclinux         EPERM
    strict   64:open_tree         ENOSYS
    strict   64:setns             EPERM
    strict   64:personality       EPERM
    strict   64:modify_ldt        EPERM
    strict   64:socket_packet     EAFNOSUPPORT
    strict   64:socket_inet       ok
    strict   64:socket_can        EAFNOSUPPORT
    strict   64:ptrace            EPERM
    strict   64:io_uring          ENOSYS
    strict   64:chroot            EPERM
    strict   64:mount             EPERM
    strict   64:netfilter         ok
    strict   64:xtables           EBADF
    strict   64:xtables6          EBADF
    strict   64:ip6_tclass        EBADF
    nesting  64:keyctl            EPERM
    nesting  64:userns            ok
    nesting  64:clone3            EINVAL
    nesting  64:tiocsti           EPERM
    nesting  64:tioclinux         EPERM
    nesting  64:open_tree         ok
    nesting  64:setns             EBADF
    nesting  64:personality       EPERM
    nesting  64:modify_ldt        EPERM
    nesting  64:socket_packet     EAFNOSUPPORT
    nesting  64:socket_inet       ok
    nesting  64:socket_can        EAFNOSUPPORT
    nesting  64:ptrace            EPERM
    nesting  64:io_uring          ENOSYS
    nesting  64:chroot            EFAULT
    nesting  64:mount             EFAULT
    nesting  64:netfilter         EPERM
    nesting  64:xtables           EPERM
    nesting  64:xtables6          EPERM
    nesting  64:ip6_tclass        EBADF
    devel    64:keyctl            EPERM
    devel    64:userns            EPERM
    devel    64:clone3            ENOSYS
    devel    64:tiocsti           EPERM
    devel    64:tioclinux         EPERM
    devel    64:open_tree         ENOSYS
    devel    64:setns             EPERM
    devel    64:personality       ok
    devel    64:modify_ldt        EPERM
    devel    64:socket_packet     EAFNOSUPPORT
    devel    64:socket_inet       ok
    devel    64:socket_can        EAFNOSUPPORT
    devel    64:ptrace            ok
    devel    64:io_uring          ENOSYS
    devel    64:chroot            EPERM
    devel    64:mount             EPERM
    devel    64:netfilter         ok
    devel    64:xtables           EBADF
    devel    64:xtables6          EBADF
    devel    64:ip6_tclass        EBADF
    steam    64:keyctl            EPERM
    steam    64:userns            ok
    steam    64:clone3            EINVAL
    steam    64:tiocsti           EPERM
    steam    64:tioclinux         EPERM
    steam    64:open_tree         ok
    steam    64:setns             EBADF
    steam    64:personality       EPERM
    steam    64:modify_ldt        ok
    steam    64:socket_packet     EAFNOSUPPORT
    steam    64:socket_inet       ok
    steam    64:socket_can        EAFNOSUPPORT
    steam    64:ptrace            EPERM
    steam    64:io_uring          ENOSYS
    steam    64:chroot            EFAULT
    steam    64:mount             EFAULT
    steam    64:netfilter         EPERM
    steam    64:xtables           EPERM
    steam    64:xtables6          EPERM
    steam    64:ip6_tclass        EBADF
    can      64:keyctl            EPERM
    can      64:userns            EPERM
    can      64:clone3            ENOSYS
    can      64:tiocsti           EPERM
    can      64:tioclinux         EPERM
    can      64:open_tree         ENOSYS
    can      64:setns             EPERM
    can      64:personality       EPERM
    can      64:modify_ldt        EPERM
    can      64:socket_packet     EAFNOSUPPORT
    can      64:socket_inet       ok
    can      64:socket_can        ok
    can      64:ptrace            EPERM
    can      64:io_uring          ENOSYS
    can      64:chroot            EPERM
    can      64:mount             EPERM
    can      64:netfilter         ok
    can      64:xtables           EBADF
    can      64:xtables6          EBADF
    can      64:ip6_tclass        EBADF
    iouring  64:keyctl            EPERM
    iouring  64:userns            EPERM
    iouring  64:clone3            ENOSYS
    iouring  64:tiocsti           EPERM
    iouring  64:tioclinux         EPERM
    iouring  64:open_tree         ENOSYS
    iouring  64:setns             EPERM
    iouring  64:personality       EPERM
    iouring  64:modify_ldt        EPERM
    iouring  64:socket_packet     EAFNOSUPPORT
    iouring  64:socket_inet       ok
    iouring  64:socket_can        EAFNOSUPPORT
    iouring  64:ptrace            EPERM
    iouring  64:io_uring          EFAULT
    iouring  64:chroot            EPERM
    iouring  64:mount             EPERM
    iouring  64:netfilter         ok
    iouring  64:xtables           EBADF
    iouring  64:xtables6          EBADF
    iouring  64:ip6_tclass        EBADF
    # User namespaces and chroot for a browser's own sandbox, with the mount calls and netfilter still shut.
    userns   64:keyctl            EPERM
    userns   64:userns            ok
    userns   64:clone3            EINVAL
    userns   64:tiocsti           EPERM
    userns   64:tioclinux         EPERM
    userns   64:open_tree         ENOSYS
    userns   64:setns             EPERM
    userns   64:personality       EPERM
    userns   64:modify_ldt        EPERM
    userns   64:socket_packet     EAFNOSUPPORT
    userns   64:socket_inet       ok
    userns   64:socket_can        EAFNOSUPPORT
    userns   64:ptrace            EPERM
    userns   64:io_uring          ENOSYS
    userns   64:chroot            EFAULT
    userns   64:mount             EPERM
    userns   64:netfilter         EPERM
    userns   64:xtables           EPERM
    userns   64:xtables6          EPERM
    userns   64:ip6_tclass        EBADF
    none     32:keyctl            ok
    none     32:userns            ok
    none     32:tiocsti           ENOTTY
    none     32:ptrace            ok
    none     32:modify_ldt        ok
    none     32:socketcall_inet   ok
    none     32:socketcall_packet EPERM
    # Without --multiarch the filter does not know the 32-bit ABI, and libseccomp kills on an unknown arch.
    strict   32:keyctl            SIGSYS
    strict   32:userns            SIGSYS
    strict   32:tiocsti           SIGSYS
    strict   32:ptrace            SIGSYS
    strict   32:modify_ldt        SIGSYS
    strict   32:socketcall_inet   SIGSYS
    strict   32:socketcall_packet SIGSYS
    steam    32:keyctl            EPERM
    steam    32:userns            ok
    steam    32:tiocsti           EPERM
    steam    32:ptrace            EPERM
    steam    32:modify_ldt        ok
    # The 32-bit Steam client creates its sockets through socketcall, so it has to keep working.
    steam    32:socketcall_inet   ok
    # EPERM from the kernel, not EAFNOSUPPORT from the filter: socketcall hides the family, so 32-bit families stay unfiltered as upstream.
    steam    32:socketcall_packet EPERM
  '';

  # A literal fd is safe only because this script allocates no other descriptors.
  runVariant =
    abi: bin: probes: name: filter:
    let
      seccomp = lib.optionalString (filter != null) "--seccomp 10";
      redirect = lib.optionalString (filter != null) "10<${filter}";
    in
    ''
      for p in ${probes}; do
        res=$(bwrap "''${base[@]}" ${seccomp} -- ${bin}/bin/probe "$p" ${redirect}) && rc=0 || rc=$?
        # bwrap reports a child killed by a signal as 128 plus its number, SIGSYS is 31.
        [ "$rc" = 159 ] && res=SIGSYS
        printf '%-8s %-21s %s\n' ${name} "${abi}:$p" "''${res:-exit$rc}"
      done
    '';

  runs =
    lib.mapAttrsToList (runVariant "64" probe probes64) variants
    ++ lib.mapAttrsToList (runVariant "32" probe32 probes32) {
      inherit (variants) none strict steam;
    };

  inherit (pkgs) lib;
in
pkgs.runCommand "confine-seccomp-behaviour" { nativeBuildInputs = [ pkgs.bubblewrap ]; } ''
  base=(--ro-bind /nix/store /nix/store --proc /proc --dev /dev --unshare-all)

  {
  ${lib.concatStrings runs}
  } > actual

  cat > expected <<'EOF'
  ${expected}EOF

  # The heredoc carries Nix indentation and attrset iteration is alphabetical.
  normalise() { awk 'NF >= 3 && $1 !~ /^#/ { print $1, $2, $3 }' "$1" | sort; }
  normalise expected > e && normalise actual > a

  # Nix build sandboxes may refuse io_uring themselves, then only the filter's bytes can show the opt-in changes anything.
  if grep -q '^none 64:io_uring ENOSYS$' a; then
    echo "io_uring is unavailable in this build sandbox, comparing filters instead" >&2
    sed -i '/64:io_uring /d' e a
    if cmp -s ${variants.strict} ${variants.iouring}; then
      echo "confine: ioUring = true builds the same filter as the default." >&2
      exit 1
    fi
  fi

  if ! diff -u e a; then
    echo "" >&2
    echo "confine: the filter no longer enforces what it claims to." >&2
    exit 1
  fi

  cp actual "$out"
''
