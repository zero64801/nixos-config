{
  lib,
  stdenv,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
}:

stdenv.mkDerivation {
  pname = "confine-security-context";
  version = "1";

  src = ./security-context.c;
  dontUnpack = true;

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
  ];
  buildInputs = [ wayland ];

  buildPhase = ''
    runHook preBuild
    xml=${wayland-protocols}/share/wayland-protocols/staging/security-context/security-context-v1.xml
    wayland-scanner client-header "$xml" security-context-v1-client-protocol.h
    wayland-scanner private-code "$xml" security-context-v1-protocol.c
    $CC -O2 -Wall -Wextra -Werror -I. -o confine-security-context "$src" security-context-v1-protocol.c \
      $(pkg-config --cflags --libs wayland-client)
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 confine-security-context "$out/bin/confine-security-context"
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
