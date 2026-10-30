{ prev, ... }:

{
  # Card Browser, a port of Marinara Engine's card browser (AGPL-3.0). SillyTavern looks for server plugins and global
  # extensions only inside its own package, so both halves are copied in. The plugin also needs enableServerPlugins in config.yaml.
  sillytavern = prev.sillytavern.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      cp -r ${./cardbrowser-plugin} $out/lib/node_modules/sillytavern/plugins/cardbrowser
      cp -r ${./cardbrowser-extension} $out/lib/node_modules/sillytavern/public/scripts/extensions/third-party/cardbrowser
    '';
  });
}
