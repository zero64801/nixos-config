{
  runCommand,
  nixfmt,
  ruff,
}:

runCommand "flatlock-lint"
  {
    nativeBuildInputs = [
      nixfmt
      ruff
    ];
  }
  ''
    find ${./..} -name '*.nix' -exec nixfmt --check {} +
    ruff check ${../_lib} ${./unit.py}
    ruff format --check ${../_lib} ${./unit.py}
    touch $out
  ''
