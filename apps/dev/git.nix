{ config, lib, ... }:

let
  cfg = config.nyx.apps.git;
in
{
  options.nyx.apps.git = {
    enable = lib.mkEnableOption "Git version control";

    email = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Email address for Git commits";
    };

    signing = {
      enable = lib.mkEnableOption "Sign commits and tags with an SSH key (e.g. YubiKey FIDO2)";

      keyFile = lib.mkOption {
        type = lib.types.str;
        default = "~/.ssh/github_yk.pub";
        description = "Path to the SSH public key used to sign commits.";
      };
    };

    github = {
      enable = lib.mkEnableOption "GitHub SSH client config (uses signing.keyFile)";
    };
  };

  config = lib.mkIf cfg.enable {
    hm.programs.git = {
      enable = true;

      settings = {
        user = {
          name = config.nyx.flake.user;
          email = cfg.email;
          signingkey = lib.mkIf cfg.signing.enable cfg.signing.keyFile;
        };
        safe.directory = "~/nixos";
        init.defaultBranch = "main";
        pull.rebase = false;

        gpg.format = lib.mkIf cfg.signing.enable "ssh";
        commit.gpgsign = lib.mkIf cfg.signing.enable true;
        tag.gpgsign    = lib.mkIf cfg.signing.enable true;
      };
    };

    hm.programs.ssh = lib.mkIf cfg.github.enable {
      enable = true;
      # Opt out of HM's deprecated implicit "*" defaults; OpenSSH's built-in
      # defaults are fine. Add an explicit "*" block here later if needed.
      enableDefaultConfig = false;
      matchBlocks."github.com" = {
        identityFile = cfg.signing.keyFile |> lib.removeSuffix ".pub";
        identitiesOnly = true;
      };
    };

    nyx.persistence.home.directories = [ ".ssh" ];
  };
}
