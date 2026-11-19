# nix build --no-link .#tests.inputs.load
# The loader of locked flakes on made up ones: a follows, a dependency of a dependency, a plain source, a flake in a subfolder, an input handed in, and nothing fetched that nothing reads.
{
  host,
}:

let
  inherit (host.pkgs) lib;

  lock = {
    root = "root";
    nodes = {
      root.inputs = {
        a = "a";
        inner = "inner";
        never = "never";
        nixpkgs = "nixpkgs";
      };
      a = {
        locked.name = "a";
        inputs = {
          b = "b";
          nixpkgs = [ "nixpkgs" ];
          plain = "plain";
        };
      };
      # Follows what a follows, which is two steps from the root.
      b = {
        locked.name = "b";
        inputs.nixpkgs = [
          "a"
          "nixpkgs"
        ];
      };
      plain = {
        flake = false;
        locked.name = "plain";
      };
      inner = {
        locked = {
          name = "sub";
          dir = "inner";
        };
      };
      never.locked.name = "never";
      # nixpkgs has no node here, as in a folder's lock: it is handed in.
    };
  };

  loaded = import ../_load.nix {
    inherit lock;
    given.nixpkgs.name = "handed in";
    fetch =
      locked:
      if locked.name == "never" then
        throw "fetched what nothing reads"
      else
        {
          outPath = ./_flakes + "/${locked.name}";
          rev = "revision of ${locked.name}";
        };
  };

  checks = {
    aFlakeIsCalledWithItsInputs = loaded.a.name == "a" && loaded.a.saw.b == "b" && loaded.a.saw.own == "a";
    aFollowsTakesWhatWasHandedIn = loaded.a.saw.nixpkgs == "handed in" && loaded.nixpkgs.name == "handed in";
    aFollowsOfADependencyIsWalkedFromTheRoot = loaded.a.saw.throughB == "handed in";
    aPlainSourceIsNotCalled = loaded.a.saw.plain == "a plain source\n" && !(loaded.a.inputs.plain ? outputs);
    aFlakeInASubfolderIsFoundThere = loaded.inner.name == "inner" && lib.hasSuffix "/sub/inner" (toString loaded.inner.outPath);
    aFlakeCarriesWhatItsSourceSays = loaded.a.rev == "revision of a" && loaded.a._type == "flake" && loaded.a.inputs.b.name == "b";
    whatNothingReadsIsNotFetched = !(builtins.tryEval loaded.never.name).success;
  };
  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (failed == [ ]) "the loader of folder inputs fails in: ${toString failed}";
"ok: the loader calls flakes with their inputs, follows, plain sources and subfolders, and fetches nothing that nothing reads"
