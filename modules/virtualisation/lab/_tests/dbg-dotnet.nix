# nix build --no-link -L .#tests.lab.dbg-dotnet
# guest-dbg's places in methods of .NET on made up memory: a real assembly's IL found as reflection gives it, in both of its layouts, JITs made to getJit's bytes in .NET Framework 4.8 and .NET 8, and the watch from before the JIT is loaded to each compile of the method.
{
  host,
}:

let
  inherit (host) pkgs;
  python = pkgs.python3.withPackages (packages: [ packages.dnfile ]);
  # Built with the C# compiler of .NET's SDK, and run once for what reflection says its methods' IL is.
  sample = pkgs.runCommand "guest-dbg-dotnet-sample" { nativeBuildInputs = [ pkgs.dotnet-sdk_8 ]; } ''
    sdk=$(dirname "$(readlink -f "$(command -v dotnet)")")
    export HOME=$TMPDIR DOTNET_CLI_TELEMETRY_OPTOUT=1
    mkdir $out
    dotnet $sdk/sdk/*/Roslyn/bincore/csc.dll -nologo -target:exe -optimize+ -out:$out/sample.dll \
      $(for f in $sdk/packs/Microsoft.NETCore.App.Ref/*/ref/net8.0/*.dll; do echo -reference:$f; done) ${./dbg_dotnet_sample.cs}
    echo '{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}' > $out/sample.runtimeconfig.json
    dotnet $out/sample.dll > $out/il.txt
  '';
in
pkgs.runCommand "guest-dbg-dotnet" { } ''
  ${python}/bin/python3 -I -B ${./dbg_dotnet_logic.py} ${../_guest-dbg} ${sample}
  touch $out
''
