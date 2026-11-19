final:

{
  # The sources a file of `pin sources` names, each fetched.
  importPins =
    path:
    final.lib.mapAttrs (_: pin: final.fetchFromGitHub { inherit (pin) owner repo rev hash; }) (builtins.fromJSON (builtins.readFile path));

  # The command that locks what folders declare for themselves, for a tool that wraps it.
  flakeInputs = final.callPackage ../inputs/_lock.nix { };

  # The head of this repository's command line tools: their colours and the four ways they speak.
  cliPrelude = ''
    # shellcheck disable=SC2034,SC2329
    {
      red=$(tput setaf 1 || echo "")
      green=$(tput setaf 2 || echo "")
      yellow=$(tput setaf 3 || echo "")
      blue=$(tput setaf 4 || echo "")
      cyan=$(tput setaf 6 || echo "")
      reset=$(tput sgr0 || echo "")
      bold=$(tput bold || echo "")

      DIM='\x1b[2m'
      NC='\x1b[0m'
      MAGENTA='\x1b[0;35m'

      die()  { echo -e "''${red}Error:''${reset} $*" >&2; exit 1; }
      info() { echo -e "''${blue}::''${reset} $*"; }
      ok()   { echo -e "''${green}✓''${reset} $*"; }
      warn() { echo -e "''${yellow}⚠''${reset} $*"; }
    }
  '';
}
