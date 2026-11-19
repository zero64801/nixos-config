{
  lib,
  stdenvNoCC,
  fetchzip,
}:

{
  pname,
  version,
  url,
  hash,
  vdfInternalName,
  description,
  homepage,
  steamDisplayName,
  passthru ? { },
}:
stdenvNoCC.mkDerivation {
  inherit pname version passthru;

  src = fetchzip {
    name = "${pname}-${version}-source";
    inherit url hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  outputs = [
    "out"
    "steamcompattool"
  ];

  installPhase = ''
    runHook preInstall

    echo "${pname} should not be installed into environments. Please use programs.steam.extraCompatPackages instead." > $out

    mkdir $steamcompattool
    ln -s $src/* $steamcompattool
    rm $steamcompattool/compatibilitytool.vdf
    cp $src/compatibilitytool.vdf $steamcompattool

    runHook postInstall
  '';

  preFixup = ''
    substituteInPlace "$steamcompattool/compatibilitytool.vdf" \
      --replace-fail "${vdfInternalName}" "${steamDisplayName}"
  '';

  meta = {
    inherit description homepage;
    license = lib.licenses.bsd3;
    maintainers = [ ];
    platforms = ["x86_64-linux"];
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
  };
}
