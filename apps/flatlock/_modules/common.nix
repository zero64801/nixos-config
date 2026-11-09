{ installation }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  model = import ./model.nix {
    inherit
      config
      lib
      pkgs
      installation
      ;
  };
  build = import ./build.nix {
    inherit
      config
      lib
      pkgs
      installation
      model
      ;
  };
in
{
  options.flatlock = import ./options.nix {
    inherit lib installation;
  };

  config = lib.mkIf config.flatlock.enable (
    import ./services.nix {
      inherit
        config
        lib
        pkgs
        installation
        model
        build
        ;
    }
  );
}
