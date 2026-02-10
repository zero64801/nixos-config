{ config, ... }:

{
  hm.programs.git = {
    enable = true;

    settings = {
      user = {
        name = config.nyx.flake.user;
        email = "dx@example.com";
      };
      safe.directory = "~/nixos";
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };
}
