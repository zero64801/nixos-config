# The C half of guest-net keys scan and keys own.
{
  stdenv,
  openssl,
}:

stdenv.mkDerivation {
  name = "tlsscan";
  src = ./tlsscan.c;
  dontUnpack = true;
  buildInputs = [ openssl ];

  # The low level hash functions are deprecated in OpenSSL 3, and still the fast way to an HMAC whose keyed state is reused.
  buildPhase = ''
    runHook preBuild
    $CC -O2 -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -fPIC -shared -pthread $src -o libtlsscan.so -lcrypto
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D libtlsscan.so $out/lib/libtlsscan.so
    runHook postInstall
  '';
}
