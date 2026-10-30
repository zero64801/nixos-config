{ prev, ... }:

{
  sillytavern = prev.sillytavern.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      cp -r ${./cardbrowser-plugin} $out/lib/node_modules/sillytavern/plugins/cardbrowser
      cp -r ${./cardbrowser-extension} $out/lib/node_modules/sillytavern/public/scripts/extensions/third-party/cardbrowser
    '';
  });
}
