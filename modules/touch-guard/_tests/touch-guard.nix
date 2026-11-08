# nix build --impure --no-link -L --expr 'import ./modules/touch-guard/_tests/touch-guard.nix { }'
{
  pkgs ? (builtins.getFlake (toString ../../..)).nixosConfigurations.Quanta.pkgs,
}:

pkgs.runCommand "touch-guard-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 -I ${./test_touch_guard.py} ${./..}
  touch $out
''
