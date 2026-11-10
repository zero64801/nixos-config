# nix build --impure --no-link -L --expr 'import ./core/_tests/polkit-kept.nix { }'
{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  # The rule file is made from the policy files in the system path, so the packages behind the cases below are installed.
  inherit
    ((import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        ../polkit.nix
        {
          nixpkgs.pkgs = pkgs;
          security.polkit.enable = true;
          environment.systemPackages = [
            pkgs.libvirt
            pkgs.modemmanager
          ];
        }
      ];
    }))
    config
    ;

  case = name: id: local: active: expect: { inherit name id local active expect; };

  cases = [
    (case "run0 and systemctl ask every time" "org.freedesktop.systemd1.manage-units" true true "auth_admin")
    (case "libvirt asks every time" "org.libvirt.unix.manage" true true "auth_admin")
    (case "an action the active session may do outright stays outright" "org.freedesktop.login1.power-off" true true null)
    (case "the same action from a remote session asks every time" "org.freedesktop.login1.power-off" false false "auth_admin")
    (case "authentication as yourself asks every time" "org.freedesktop.ModemManager1.Device.Control" true true "auth_self")
    (case "an inactive session keeps a default that remembers nothing" "org.freedesktop.systemd1.manage-units" true false null)
    (case "unknown actions are left alone" "org.example.Unknown" true true null)
  ];

  prelude = pkgs.writeText "prelude.js" ''
    var rules = [];
    var polkit = {
      Result: { YES: "yes", NO: "no", AUTH_SELF: "auth_self", AUTH_ADMIN: "auth_admin", AUTH_ADMIN_KEEP: "auth_admin_keep", NOT_HANDLED: null },
      addRule: function (f) { rules.push(f); },
      addAdminRule: function () {},
      log: function () {}
    };
  '';

  check = pkgs.writeText "check.js" ''
    var cases = ${builtins.toJSON cases};
    var failed = 0;
    for (var i = 0; i < cases.length; i++) {
      var c = cases[i];
      var got = rules[0]({ id: c.id }, { local: c.local, active: c.active });
      if (got === undefined) got = null;
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
pkgs.runCommand "polkit-kept-test" { nativeBuildInputs = [ pkgs.duktape ]; } ''
  cat ${prelude} ${config.environment.etc."polkit-1/rules.d/zz-no-kept-approvals.rules".source} ${check} > test.js
  duk test.js
  touch $out
''
