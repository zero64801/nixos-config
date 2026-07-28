{ lib, stdenv, runCommand, libseccomp }:

let
  compiler = stdenv.mkDerivation {
    pname = "confine-seccomp";
    version = "1";

    src = ./seccomp.c;
    dontUnpack = true;

    buildInputs = [ libseccomp ];

    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -Werror -o confine-seccomp "$src" -lseccomp
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 confine-seccomp "$out/bin/confine-seccomp"
      runHook postInstall
    '';

    meta.platforms = lib.platforms.linux;
  };
in
# Exported BPF is bytecode for the producing arch, build and host must match.
{
  nesting ? false,
  devel ? false,
  multiarch ? false,
  bluetooth ? false,
  can ? false,
}:

let
  flags =
    lib.optional nesting "--allow-nesting"
    ++ lib.optional devel "--devel"
    ++ lib.optional multiarch "--multiarch"
    ++ lib.optional bluetooth "--allow-bluetooth"
    ++ lib.optional can "--allow-can";

  suffix = if flags == [ ] then "strict" else lib.concatStringsSep "-" (map (lib.removePrefix "--") flags);
in
runCommand "confine-filter-${suffix}.bpf" { preferLocalBuild = true; } ''
  ${compiler}/bin/confine-seccomp ${lib.escapeShellArgs flags} > "$out"
''
