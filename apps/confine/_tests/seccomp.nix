# nix build --impure --no-link --expr 'import ./apps/confine/_tests/seccomp.nix { }'
# The "none" column proves a change comes from the filter, not unprivileged refusal.
{
  pkgs ? import <nixpkgs> { },
}:

let
  mkFilter = pkgs.callPackage ../_lib/seccomp.nix { };

  probe = pkgs.runCommandCC "confine-seccomp-probe" { } ''
    mkdir -p "$out/bin"
    $CC -O2 -Wall -Wextra -Werror -o "$out/bin/probe" ${./seccomp-probe.c}
  '';

  variants = {
    none = null;
    strict = mkFilter { };
    nesting = mkFilter { nesting = true; };
    devel = mkFilter { devel = true; };
    # A second arch token changes which rules libseccomp will accept at all.
    steam = mkFilter {
      nesting = true;
      multiarch = true;
      bluetooth = true;
    };
    # The one escape hatch whose effect a probe can actually observe here.
    can = mkFilter { can = true; };
  };

  # nesting must reopen only the namespace group, devel only the debugging group.
  expected = ''
    none          keyctl        ok
    none          userns        ok
    none          clone3        EINVAL
    none          tiocsti       ENOTTY
    none          socket_packet EPERM
    none          socket_can    ok
    none          socket_inet   ok
    none          ptrace        ok
    strict        keyctl        EPERM
    strict        userns        EPERM
    strict        clone3        ENOSYS
    strict        tiocsti       EPERM
    strict        socket_packet EAFNOSUPPORT
    strict        socket_can    EAFNOSUPPORT
    strict        socket_inet   ok
    strict        ptrace        EPERM
    nesting       keyctl        EPERM
    nesting       userns        ok
    nesting       clone3        EINVAL
    nesting       tiocsti       EPERM
    nesting       socket_packet EAFNOSUPPORT
    nesting       socket_can    EAFNOSUPPORT
    nesting       socket_inet   ok
    nesting       ptrace        EPERM
    devel         keyctl        EPERM
    devel         userns        EPERM
    devel         clone3        ENOSYS
    devel         tiocsti       EPERM
    devel         socket_packet EAFNOSUPPORT
    devel         socket_can    EAFNOSUPPORT
    devel         socket_inet   ok
    devel         ptrace        ok
    steam         keyctl        EPERM
    steam         userns        ok
    steam         clone3        EINVAL
    steam         tiocsti       EPERM
    # EPERM not EAFNOSUPPORT: the 32-bit arch makes libseccomp drop the
    # socket-family rules, the kernel refuses AF_PACKET for lack of CAP_NET_RAW.
    steam         socket_packet EPERM
    steam         socket_can    ok
    steam         socket_inet   ok
    steam         ptrace        EPERM
    can           keyctl        EPERM
    can           userns        EPERM
    can           clone3        ENOSYS
    can           tiocsti       EPERM
    can           socket_packet EAFNOSUPPORT
    can           socket_can    ok
    can           socket_inet   ok
    can           ptrace        EPERM
  '';

  # A literal fd is safe only because this script allocates no other descriptors.
  runVariant =
    name: filter:
    let
      seccomp = lib.optionalString (filter != null) "--seccomp 10";
      redirect = lib.optionalString (filter != null) "10<${filter}";
    in
    ''
      for p in $probes; do
        printf '%-13s %-13s %s\n' ${name} "$p" \
          "$(bwrap "''${base[@]}" ${seccomp} -- ${probe}/bin/probe "$p" ${redirect})"
      done
    '';

  inherit (pkgs) lib;
in
pkgs.runCommand "confine-seccomp-behaviour" { nativeBuildInputs = [ pkgs.bubblewrap ]; } ''
  base=(--ro-bind /nix/store /nix/store --proc /proc --dev /dev --unshare-all)
  probes="keyctl userns clone3 tiocsti socket_packet socket_inet socket_can ptrace"

  {
  ${lib.concatStrings (lib.mapAttrsToList runVariant variants)}
  } > actual

  cat > expected <<'EOF'
  ${expected}EOF

  # The heredoc carries Nix indentation and attrset iteration is alphabetical.
  normalise() { awk 'NF >= 3 && $1 !~ /^#/ { print $1, $2, $3 }' "$1" | sort; }
  normalise expected > e && normalise actual > a

  if ! diff -u e a; then
    echo "" >&2
    echo "confine: the filter no longer enforces what it claims to." >&2
    exit 1
  fi

  cp actual "$out"
''
