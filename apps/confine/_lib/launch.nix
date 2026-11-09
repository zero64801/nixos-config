{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "confine-launch";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./launch;
    fileset = lib.fileset.unions [
      ./launch/Cargo.toml
      ./launch/Cargo.lock
      ./launch/src
    ];
  };

  cargoLock.lockFile = ./launch/Cargo.lock;

  meta = {
    description = "confine's sandbox launcher";
    mainProgram = "confine-launch";
    platforms = lib.platforms.linux;
  };
}
