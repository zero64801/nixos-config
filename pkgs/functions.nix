inputs: final: prev:
let
  inherit (prev) pkgs lib;
in
{
  # Create a simple systemd service
  mkSimpleService = { name, description, script, wantedBy ? [ "multi-user.target" ], ... }: {
    systemd.services.${name} = {
      inherit description;
      wantedBy = wantedBy;
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "${name}-script" script;
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };

  # Write a Nix script with proper shebang
  writeNixShellScript = name: script: pkgs.writeTextFile {
    name = name;
    executable = true;
    destination = "/bin/${name}";
    text = ''
      #!${pkgs.runtimeShell}
      ${script}
    '';
  };
}
