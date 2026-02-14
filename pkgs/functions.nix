inputs: final: prev:
let
  inherit (prev) lib;
in
{
  util = {
    importFlake = path:
      (import inputs.flake-compat { src = path; }).defaultNix;
  };

  wrapPackage = pkg: scriptFn:
    let
      exe = lib.getExe pkg;
      name = pkg.pname or pkg.name or (builtins.parseDrvName pkg.name).name;
    in final.writeShellScriptBin name (scriptFn exe);

  aliasToPackage = aliases:
    let
      scripts = lib.mapAttrsToList (name: command:
        final.writeShellScriptBin name command
      ) aliases;
    in final.symlinkJoin {
      name = "aliases";
      paths = scripts;
    };

  matchPackageCommand = pkg: command:
    let
      name = lib.getName pkg;
    in ''
      if command -v ${lib.getExe pkg} &>/dev/null; then
        ${command} "$@"
      else
        command ${name} "$@"
      fi
    '';

  wrapEnv = pkg: envVars:
    let
      name = pkg.pname or pkg.name or (builtins.parseDrvName pkg.name).name;
      envFlags = lib.concatStringsSep " "
        (lib.mapAttrsToList (k: v: "--set ${k} ${lib.escapeShellArg v}") envVars);
    in final.runCommand name {
      nativeBuildInputs = [ final.makeWrapper ];
    } ''
      mkdir -p $out/bin
      for bin in ${pkg}/bin/*; do
        makeWrapper "$bin" "$out/bin/$(basename "$bin")" ${envFlags}
      done

      if [ -d "${pkg}/share" ]; then
        ln -s ${pkg}/share $out/share
      fi
    '';

  pkgs-stable = import inputs.stable {
    inherit (prev) config;
    inherit (prev.stdenv.hostPlatform) system;
  };
}
