{ runCommand, python3 }:

runCommand "flatlock-unit-tests"
  {
    nativeBuildInputs = [ python3 ];
  }
  ''
    FLATLOCK_LIB=${../_lib} python3 ${./unit.py}
    touch $out
  ''
