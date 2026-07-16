{ installation }:
{
  config,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:

let
  hostname =
    if installation == "system" then
      config.networking.hostName
    else if osConfig != null then
      osConfig.networking.hostName
    else
      config.home.username;
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
      hostname
      model
      ;
  };
in
{
  options.flatlock = import ./options.nix {
    inherit lib installation hostname;
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
