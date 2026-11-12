{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  pkg-config,
  fuse3,
  libusb1,
  openssl,
}:

let
  upstream =
    repo: rev: hash:
    fetchFromGitHub {
      name = repo;
      owner = "ufrisk";
      inherit repo rev hash;
    };

  # Fetches and reads Microsoft's debug symbols, which most of what MemProcFS shows of a Windows guest is built on.
  pdbcrust = rustPlatform.buildRustPackage {
    pname = "pdbcrust";
    version = "1.0.0";
    src =
      upstream "pdbcrust" "19dd370ea53307251b1bea08906d5da653aa76cd"
        "sha256-3PStkW3q4FJFeBmujYxhdhm2fUYCD3ayRtL/sAjumpY=";

    # Upstream ships no lock file.
    cargoLock.lockFile = ./_memprocfs/pdbcrust.Cargo.lock;
    postPatch = "ln -s ${./_memprocfs/pdbcrust.Cargo.lock} Cargo.lock";

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ openssl ];
    doCheck = false;
  };
in
stdenv.mkDerivation {
  pname = "memprocfs";
  version = "5.19.3";

  srcs = [
    (upstream "MemProcFS" "6490ad8bc322d0446e041b80bd40070a38f63fe3"
      "sha256-E8guMznQ4pvlvRpCWFJj2HrkCdkx3kZT92qma53xwmU="
    )
    (upstream "LeechCore" "23f1919853d4e365e6873576e0f58176c84f81a4"
      "sha256-evtahnp8XFOcq47DdacXtdD/vz260ytsaHW/GnoYtWI="
    )
    (upstream "LeechCore-plugins" "90466f3332f0a6b35dc8d00d7b4bc3b47ab4c329"
      "sha256-FqorJCgLvPxRG2CfHMH1rfZEjPp7GXoC1SkYx6r/QYs="
    )
  ];
  sourceRoot = ".";

  # A guest's RAM under libvirt is usually a memfd, which has no path to open. The ram parameter takes it as a
  # descriptor from a unix socket, so whoever may open it decides who gets it.
  # The front end is written against FUSE 2, which nixpkgs no longer has. Downloaded symbols go beside the libraries,
  # which here is the read only store, so they go to the user's cache folder to be kept between runs.
  postPatch = ''
    patch -p1 -d LeechCore-plugins < ${./_memprocfs/qemu-ram-socket.patch}
    patch -p1 -d MemProcFS < ${./_memprocfs/fuse3.patch}
    patch -p1 -d MemProcFS < ${./_memprocfs/symbol-cache.patch}
    substituteInPlace LeechCore-plugins/leechcore_device_qemu/Makefile --replace-fail " -Werror" ""
  '';

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    fuse3
    libusb1
  ];

  # Each part looks for the ones before it in a files folder beside its own, and at run time in its own folder.
  buildPhase = ''
    runHook preBuild
    make -C LeechCore/leechcore
    make -C LeechCore-plugins/leechcore_device_qemu
    mkdir -p MemProcFS/files
    cp LeechCore/files/leechcore.so MemProcFS/files/
    make -C MemProcFS/vmm
    make -C MemProcFS/memprocfs
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/memprocfs $out/bin $out/include
    cp MemProcFS/files/leechcore.so MemProcFS/files/vmm.so MemProcFS/files/memprocfs $out/lib/memprocfs/
    cp LeechCore-plugins/files/leechcore_device_qemu.so $out/lib/memprocfs/
    cp ${pdbcrust}/lib/libpdbcrust.so $out/lib/memprocfs/
    cp MemProcFS/includes/vmmdll.h LeechCore/includes/leechcore.h $out/include/
    ln -s $out/lib/memprocfs/memprocfs $out/bin/memprocfs
    runHook postInstall
  '';

  meta = {
    description = "Memory of a running or dumped Windows system as files, with the LeechCore QEMU device";
    homepage = "https://github.com/ufrisk/MemProcFS";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "memprocfs";
  };
}
