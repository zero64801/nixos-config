{ runCommand, python3 }:

runCommand "flatlock-lock-validation"
  {
    nativeBuildInputs = [ python3 ];
  }
  ''
    python3 ${../_lib}/validate-lock.py ${./fixtures/valid.lock}

    if python3 ${../_lib}/validate-lock.py ${./fixtures/malformed.lock}; then
      echo "malformed lock unexpectedly passed validation" >&2
      exit 1
    fi

    if python3 ${../_lib}/validate-lock.py ${./fixtures/invalid.lock}; then
      echo "invalid lock schema unexpectedly passed validation" >&2
      exit 1
    fi

    if python3 ${../_lib}/validate-lock.py ${./fixtures/unsupported.lock}; then
      echo "unsupported lock version unexpectedly passed validation" >&2
      exit 1
    fi

    touch $out
  ''
