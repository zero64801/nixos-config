{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpm_10,
  pnpmConfigHook,
  nodejs_24,
  makeWrapper,
  node-gyp,
  pkg-config,
  python3,
  vips,
  openssl,
}:

let
  pnpm = pnpm_10.override { nodejs = nodejs_24; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "marinara-engine";
  version = "1.5.9";

  src = fetchFromGitHub {
    owner = "Pasta-Devs";
    repo = "Marinara-Engine";
    tag = "v${finalAttrs.version}";
    hash = "sha256-SyWrRjeMjaZP9rJPn4fKukp3YT2bBZ2FmXZZsc4T8gQ=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 2;
    prePnpmInstall = ''
      mkdir -p $out
      sed -i '/^store-dir=/d' .npmrc
    '';
    hash = "sha256-/OKE4f4EXFfgBctX6zrQcmYQ2lo2dgJdRzkCzoIAfDA=";
  };

  nativeBuildInputs = [
    node-gyp
    nodejs_24
    makeWrapper
    pkg-config
    pnpm
    pnpmConfigHook
    python3
  ];

  buildInputs = [
    openssl
    vips
  ];

  env = {
    NODE_PATH = "${node-gyp}/lib/node_modules";
    npm_config_nodedir = "${nodejs_24}";
  };

  pnpmInstallFlags = [ "--force" ];
  dontCheckForBrokenSymlinks = true;

  postPatch = ''
    sed -i '/^store-dir=/d' .npmrc

    substituteInPlace packages/server/src/config/runtime-config.ts \
      --replace-fail 'export function getEnvFilePath() {
  return resolve(MONOREPO_ROOT, ".env");
}' 'export function getEnvFilePath() {
  const raw = normalizeEnvValue(process.env.MARINARA_ENV_FILE);
  if (raw) return isAbsolute(raw) ? raw : resolveFromServerRoot(raw);
  return resolve(MONOREPO_ROOT, ".env");
}'

    substituteInPlace packages/server/scripts/write-build-meta.mjs \
      --replace-fail 'builtAt: new Date().toISOString()' \
                     'builtAt: new Date(Number(process.env.SOURCE_DATE_EPOCH ?? 0) * 1000).toISOString()'
  '';

  buildPhase = ''
    runHook preBuild

    pnpm build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    rm -rf node_modules packages/*/node_modules
    pnpm config set node-linker hoisted
    pnpm install --offline --prod --ignore-scripts --frozen-lockfile

    mkdir -p $out/share/marinara-engine $out/bin
    cp -r package.json pnpm-workspace.yaml .env.example node_modules packages docs $out/share/marinara-engine/

    makeWrapper ${lib.getExe nodejs_24} $out/bin/marinara-engine \
      --chdir "$out/share/marinara-engine/packages/server" \
      --run 'export DATA_DIR="''${DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/marinara-engine}"' \
      --run 'mkdir -p "$DATA_DIR"' \
      --run 'export MARINARA_ENV_FILE="''${MARINARA_ENV_FILE:-$DATA_DIR/.env}"' \
      --run 'export HOST="''${HOST:-127.0.0.1}"' \
      --run 'export PORT="''${PORT:-7860}"' \
      --run 'export NODE_ENV="''${NODE_ENV:-production}"' \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [
        openssl
        vips
      ]} \
      --add-flags "$out/share/marinara-engine/packages/server/dist/index.js"

    runHook postInstall
  '';

  meta = {
    description = "Local AI-powered chat, roleplay, and game engine";
    homepage = "https://github.com/Pasta-Devs/Marinara-Engine";
    changelog = "https://github.com/Pasta-Devs/Marinara-Engine/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    mainProgram = "marinara-engine";
    platforms = lib.platforms.linux;
  };
})
