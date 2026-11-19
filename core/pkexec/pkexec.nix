{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  cfg = config.my.security.pkexecNoAuth;

  allowed = map (e: {
    inherit (e) program;
    lines = if e.args == null then null else map (a: lib.concatStringsSep " " ([ e.program ] ++ a)) e.args;
  }) cfg;
in
{
  options.my.security.pkexecNoAuth = mkOption {
    type = types.listOf (types.submodule {
      options = {
        program = mkOption {
          type = types.str;
          description = "Absolute store path pkexec runs. Matched exactly, never as a prefix.";
        };
        args = mkOption {
          type = types.nullOr (types.listOf (types.listOf types.str));
          default = null;
          description = ''
            Exact argument lists that need no authentication. null allows any
            arguments, so the program itself must validate its argv.
            Other argument lists fall back to the default pkexec policy.
          '';
        };
      };
    });
    default = [ ];
    description = "Programs wheel members may run as root through pkexec without authenticating.";
  };

  config = lib.mkIf (cfg != [ ]) {
    assertions = map (e: {
      assertion = lib.hasPrefix "/nix/store/" e.program;
      message = "my.security.pkexecNoAuth: ${e.program} is not a store path.";
    }) cfg;

    # polkit joins argv with single spaces into command_line, so an argument containing a space can mimic an allowed list. Programs with an args list must reject such arguments.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id != "org.freedesktop.policykit.exec" || !subject.isInGroup("wheel")) {
          return polkit.Result.NOT_HANDLED;
        }
        var allowed = ${builtins.toJSON allowed};
        var program = action.lookup("program");
        var line = action.lookup("command_line");
        for (var i = 0; i < allowed.length; i++) {
          var e = allowed[i];
          if (e.program === program && (e.lines === null || e.lines.indexOf(line) >= 0)) {
            return polkit.Result.YES;
          }
        }
        return polkit.Result.NOT_HANDLED;
      });
    '';
  };
}
