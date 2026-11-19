# A made up host of this repository's shared modules, put together as a host is, for the tests of shared modules to build on.
# A test names the folders a fork may delete that it wants left out, and none it wants loaded, so that a folder that is gone takes nothing with it but its own tests.
{
  flake,
  system,
}:

let
  inherit (flake) inputs;
  inherit (inputs.nixpkgs) lib;
  repo = import "${flake}/hosts.nix" { inherit inputs; };
  name = "fixture";

  # Who the made up host is, which a machine that is booted takes too.
  identity = {
    my.flake.user = "alice";
    my.flakePath = "/etc/nixos";
    users.users.alice.isNormalUser = true;
    system.stateVersion = "25.11";
  };

  # What a host that is only evaluated has where a booted machine has its own: a name, a disk and a boot loader.
  machine = {
    networking.hostName = name;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    boot.loader.grub.devices = [ "nodev" ];
    nixpkgs.hostPlatform = system;
  };

  # The shared modules without those of the folders named, by the rule a host leaves folders out with.
  modules = repo.keep;

  plain = repo.system name (modules [ ] ++ [ identity machine ]);

  # A fault in a shared module shows in every test that builds on this host, so the one place that can tell says which kind it is.
  sound = (builtins.tryEval (builtins.seq plain.config true)).success;
  packages =
    (
      if sound then
        plain
      else
        builtins.trace "note: the made up host fails with none of this test's settings, so the fault is in a shared module and not in what this test is about" plain
    ).pkgs;

  # A variant that asks for the packages the plain host has takes those, and any other works out its own.
  shares =
    { config, ... }:
    let
      asked = config.nixpkgs;
      same = lib.length asked.overlays == lib.length plain.config.nixpkgs.overlays && asked.config == plain.config.nixpkgs.config;
    in
    {
      _module.args.pkgs = lib.mkIf same (lib.mkForce packages);
    };

  evaluate =
    {
      without ? [ ],
      config ? { },
    }:
    repo.system name (
      modules without
      ++ [
        identity
        machine
        shares
        config
      ]
    );

  refused =
    given:
    let
      made = evaluate given;
      # The words of an assertion are read only once it fails, since they may make no sense before.
      failed = map (said: said.message) (builtins.filter (said: !said.assertion) made.config.assertions);
    in
    if failed != [ ] then failed else builtins.seq made.config.system.build.toplevel.drvPath [ ];

  has = thing: builtins.pathExists "${flake}/${thing}";

  needed =
    things: test:
    let
      gone = builtins.filter (thing: !has thing) things;
    in
    if gone == [ ] then test else "skipped: ${toString gone} is not in this repository";
in
{
  # The packages of the made up host, which its variants share where they can, so that they are worked out once.
  pkgs = packages;

  # The modules, with those of the folders named left out.
  inherit modules;

  # What a host's _without.nix leaves out, read as the hosts' own are.
  inherit (repo) leftOut;

  # The made up host as a system to look at.
  # without: folders or module files below the repository's root, as "apps/confine", whose modules are left out.
  inherit evaluate;

  # What a rebuild of that system would be refused with: the words of each assertion that fails, and none where it would go through.
  inherit refused;

  # needs [ "apps/confine" ] test is the test, or a line in its place where a fork deleted what it names, so that the other tests still run.
  needs = needed;

  # A test that boots: each machine under machines is the made up host under the name the test gives it, with what the test says of it and without the folders under without.
  # A machine under nodes is none of this repository's, as a server elsewhere is, and whatever else is given goes to the test as it is.
  # What is under needs is what the test cannot do without, as for needs above.
  boot =
    {
      without ? [ ],
      needs ? [ ],
      machines,
      ...
    }@test:
    needed needs (
      packages.testers.runNixOSTest {
        imports = [ (removeAttrs test [ "without" "needs" "machines" ]) ];
        node = {
          specialArgs = repo.specialArgs name;
          # The shared modules set what the packages are made with, which a machine that is handed its packages may not.
          pkgsReadOnly = false;
        };
        nodes = lib.mapAttrs (_: said: { imports = modules without ++ [ identity shares said ]; }) machines;
      }
    );

  # A test of modules turned on in a fork that deleted something they read from, which deleting things with nothing turned on does not show.
  # Each case names under on the module files its settings turn on, the one that reads first, then what is gone, and the settings.
  # Where the reader cannot do without what is gone, the case gives under refused a part of the words a rebuild has to be refused with.
  bare =
    cases:
    let
      tried = builtins.filter (case: lib.all has case.on) cases;
      label = case: "${lib.head case.on} without ${case.gone}";
      said =
        case:
        builtins.addErrorContext "with ${lib.head case.on} turned on and ${case.gone} deleted" (refused {
          without = [ case.gone ];
          inherit (case) config;
        });
      holds = case: if case ? refused then lib.any (lib.hasInfix case.refused) (said case) else said case == [ ];
      wrong = builtins.filter (case: !holds case) tried;
      ended = case: if said case == [ ] then "went through" else "was refused with: ${toString (said case)}";
    in
    assert lib.assertMsg (wrong == [ ]) "these do not end as they should: ${
      lib.concatMapStringsSep ", " (case: "${label case} ${ended case}") wrong
    }";
    "ok: ${toString (lib.length tried)} modules turned on with something they read from deleted";
}
