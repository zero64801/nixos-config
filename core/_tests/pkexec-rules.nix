# nix build --impure --no-link -L --expr 'import ./core/_tests/pkexec-rules.nix { }'
{
  system ? (builtins.getFlake (toString ../..)).nixosConfigurations.Quanta,
}:

let
  inherit (system) pkgs config;
  inherit (pkgs) lib;

  line = program: args: lib.concatStringsSep " " ([ program ] ++ args);

  exec = name: program: args: groups: expect: {
    inherit name groups expect;
    id = "org.freedesktop.policykit.exec";
    details = {
      inherit program;
      command_line = line program args;
    };
  };

  casesFor =
    e:
    if e.args == null then
      [
        (exec "${e.program} with any arguments" e.program [ "anything" ] [ "wheel" ] "yes")
        (exec "a path extending ${e.program}" "${e.program}-x" [ ] [ "wheel" ] null)
        (exec "${e.program} outside wheel" e.program [ ] [ "users" ] null)
      ]
    else
      map (a: exec "${line e.program a}" e.program a [ "wheel" ] "yes") e.args
      ++ map (a: exec "${line e.program a} with an extra argument" e.program (a ++ [ "x" ]) [ "wheel" ] null) e.args
      ++ [ (exec "${e.program} outside wheel" e.program (lib.head e.args) [ "users" ] null) ];

  scx = "${config.my.apps.scx.package}/bin/scx-switch";

  cases =
    lib.concatMap casesFor config.my.security.pkexecNoAuth
    ++ [
      (exec "scx-switch apply scx_chaos" scx [ "apply" "scx_chaos" ] [ "wheel" ] null)
      (exec "scx-switch apply with custom flags" scx [ "apply" "scx_lavd" "--slice-max-us" "1" ] [ "wheel" ] null)
      {
        name = "another action with an allowed program";
        id = "org.freedesktop.systemd1.manage-units";
        details.program = scx;
        groups = [ "wheel" ];
        expect = null;
      }
    ];

  script = pkgs.writeText "pkexec-rules-test.js" ''
    var rules = [];
    var polkit = {
      Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin", AUTH_ADMIN_KEEP: "auth_admin_keep", NOT_HANDLED: null },
      addRule: function (f) { rules.push(f); },
      addAdminRule: function () {},
      log: function () {}
    };

    ${config.security.polkit.extraConfig}

    var cases = ${builtins.toJSON cases};
    var failed = 0;
    for (var i = 0; i < cases.length; i++) {
      var c = cases[i];
      var action = { id: c.id, lookup: function (k) { return c.details[k]; } };
      var subject = {
        user: "dx", local: true, active: true,
        isInGroup: function (g) { return c.groups.indexOf(g) >= 0; }
      };
      var got = null;
      for (var r = 0; r < rules.length && got === null; r++) {
        var v = rules[r](action, subject);
        if (v !== undefined && v !== null) got = v;
      }
      if (got === c.expect) {
        print("ok   " + c.name);
      } else {
        failed++;
        print("FAIL " + c.name + ": expected " + c.expect + ", got " + got);
      }
    }
    if (failed > 0) throw new Error(failed + " polkit cases failed");
  '';
in
pkgs.runCommand "pkexec-rules-test" { nativeBuildInputs = [ pkgs.duktape ]; } ''
  duk ${script}
  touch $out
''
