{
  lib,
  stdenv,
  pkg-config,
  systemdLibs,
}:

stdenv.mkDerivation {
  pname = "confine-helpers";
  version = "1";

  dontUnpack = true;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ systemdLibs ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -o confine-document-add ${./document-add.c} $(pkg-config --cflags --libs libsystemd)
    $CC -O2 -Wall -Wextra -Werror -o confine-seccomp-exec ${./seccomp-exec.c}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 confine-document-add "$out/bin/confine-document-add"
    install -Dm755 confine-seccomp-exec "$out/bin/confine-seccomp-exec"
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
