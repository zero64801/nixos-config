# nix build --no-link -L .#tests.lab.lab
# The lab on a system that is none of this repository's hosts: by itself, with a mode and a tool another module adds, and with no confine module there.
{
  host,
}:

let
  fixture = import ./fixture.nix { inherit host; };
  inherit (fixture) pkgs opened command failures settings;
  inherit (pkgs) lib;

  # The lab by itself, without the folder of its agent, which adds to it.
  evalWith =
    {
      without ? [ ],
    }:
    fixture.evalWith { without = without ++ [ "modules/virtualisation/lab/agent" ]; };

  alone = evalWith { } {
    inspect = opened;
    lab.enable = true;
  };

  moded = evalWith { } {
    inspect = opened;
    lab = {
      enable = true;
      limits.MemoryMax = "2G";
      modes.note = {
        summary = ''
          start with a notebook that is kept
          and a second line about it
        '';
        kept.lab-notes = ".notes";
        start = ''set -- echo "note for $domain:" "$@"'';
      };
      tools.lab-note = {
        package = pkgs.hello;
        summary = ''
          reads the notebook
          and a second line about it
        '';
      };
    };
  };

  misnamed =
    name:
    evalWith { } {
      inspect = opened;
      lab = {
        enable = true;
        modes.${name} = {
          summary = "a mode";
          start = "";
        };
      };
    };

  unopened = evalWith { } { lab.enable = true; };
  uninspected = evalWith { without = [ "modules/virtualisation/inspect" ]; } { lab.enable = true; };

  bare = evalWith { without = [ "apps/confine" ]; } {
    inspect = opened;
    lab.enable = true;
  };

  bareByChoice = evalWith { } {
    inspect = opened;
    lab = {
      enable = true;
      sandbox = null;
    };
  };

  checks = {
    labWithoutInspectIsRefused = failures "my.virtualisation.inspect.enable" unopened != [ ];
    labWithoutTheInspectModuleIsRefused = failures "the vm-inspect module" uninspected != [ ];
    labNeedsNoConfine = failures "my.virtualisation.lab" bare == [ ] && command "vm-lab" bare != null;
    choosingNoSandboxGivesTheSameLab = (command "vm-lab" bareByChoice).outPath == (command "vm-lab" bare).outPath;
    toolOfAnotherModuleIsInTheLab =
      lib.elem pkgs.hello moded.system.build.vmLabTools.paths && !lib.elem pkgs.hello alone.system.build.vmLabTools.paths;
    modeNamesAreChecked =
      failures "my.virtualisation.lab.modes" (misnamed "Note") != [ ]
      && failures "my.virtualisation.lab.modes" (misnamed "join") != [ ]
      && failures "my.virtualisation.lab.modes" moded == [ ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
# The sandbox the lab gets from confine is half of what is looked at here. bare-lab.nix is the lab of a fork without it.
host.needs [ "apps/confine" "modules/virtualisation/inspect" ] (
  assert lib.assertMsg (failed == [ ]) "vm-lab module checks failed: ${lib.concatStringsSep ", " failed}";
  pkgs.runCommand "vm-lab-test" { } ''
    ${settings}
    alone=${alone.my.virtualisation.lab.package}/bin/vm-lab
    moded=${moded.my.virtualisation.lab.package}/bin/vm-lab

    "$alone" --help > alone.help
    grep -q guest-mount alone.help
    if grep -q -- "--note\|lab-note\|guest-mcp\|--agent" alone.help; then
      echo "a lab by itself shows what only another module adds"
      exit 1
    fi
    if "$alone" --note guest 2> alone.refused; then
      echo "a lab without modes took one"
      exit 1
    fi
    grep -q "unknown option --note" alone.refused
    grep -q '/etc/nixos#nixosConfigurations.fixture.config.system.build.vmLabTools' "$alone"
    limited=$(settings "$alone" ----)
    full=$(settings "$alone" --f-)
    grep -q '"MemoryMax","32G"' "$limited"
    if grep -q MemoryMax "$full"; then
      echo "a full lab is limited"
      exit 1
    fi

    "$moded" --help > moded.help
    grep -qx "       vm-lab --note \[--join\] DOMAIN \[ARGUMENT...\]" moded.help
    grep -qx "  --note     start with a notebook that is kept" moded.help
    grep -qx "             and a second line about it" moded.help
    grep -qx "  lab-note      reads the notebook" moded.help
    grep -qx "                and a second line about it" moded.help
    limited=$(settings "$moded" ----)
    grep -q '"MemoryMax","2G"' "$limited"
    inside=$(settings "$moded" ---note)
    grep -q '"xdg-state/lab-notes"' "$inside"
    grep -q '".notes"' "$inside"
    if grep -q "lab-notes" "$limited"; then
      echo "a lab outside the mode has the mode's folder"
      exit 1
    fi

    bare=${bare.my.virtualisation.lab.package}/bin/vm-lab
    "$bare" --help > bare.help
    grep -q "without a sandbox" bare.help
    grep -q guest-mount bare.help
    if grep -q -- "--online\|--full" bare.help || grep -qi "confine" "$bare"; then
      echo "a lab without a sandbox still speaks of one"
      exit 1
    fi
    if "$bare" --online guest 2> bare.refused; then
      echo "a lab without a sandbox took --online"
      exit 1
    fi
    grep -q "unknown option --online" bare.refused

    touch $out
  ''
)
