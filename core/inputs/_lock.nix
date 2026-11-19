# The command that locks what folders declare for themselves, for `nix run .#inputs` and for whatever wraps it.
{
  writeShellApplication,
  coreutils,
  git,
  gnugrep,
  jq,
  util-linux,
}:

writeShellApplication {
  name = "flake-inputs";
  # Nix is not among them: the one that started this is the one that knows the settings of the system it runs on.
  runtimeInputs = [
    coreutils
    git
    gnugrep
    jq
    util-linux
  ];
  text = ''
    scratch=${./_scratch.nix}
  ''
  + builtins.readFile ./_lock.sh;
}
