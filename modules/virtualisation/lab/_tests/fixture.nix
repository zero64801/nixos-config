# What the lab's tests share: the made up host of the repository's shared modules, with the lab's settings given.
{
  host,
}:

let
  inherit (host) pkgs;
  inherit (pkgs) lib;
in
{
  inherit pkgs;

  # without: folders the made up host leaves out, as "apps/confine".
  evalWith =
    {
      without ? [ ],
    }:
    virtualisation:
    (host.evaluate {
      inherit without;
      config = {
        security.polkit.enable = true;
        security.polkit.enablePkexecWrapper = true;
        my.virtualisation = virtualisation;
      };
    }).config;

  opened = {
    enable = true;
    domains = [ "guest" ];
  };

  command = name: config: lib.findFirst (p: (p.name or "") == name) null config.environment.systemPackages;

  # Whether it holds first, since the words of an assertion may only make sense once it does not.
  failures = part: config: lib.filter (a: !a.assertion && lib.hasInfix part a.message) config.assertions;

  # For a test's script: the settings file of the sandbox that vm-lab $1 starts for the choice $2.
  settings = ''
    settings() {
      local launcher
      launcher=$(grep -- "^ *$2)" "$1" | grep -o '/nix/store/[^ ]*')
      sed -n 2p "''${launcher:?}" | cut -d' ' -f2
    }
  '';
}
