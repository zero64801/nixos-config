{ ... }:

{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "dx";
        email = "dx@example.com";
      };
      safe.directory = "~/nixos";
      init.defaultBranch = "main";
      pull.rebase = false;
    };
  };
}
