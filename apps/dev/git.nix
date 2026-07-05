{ config, lib, ... }:

let
  cfg = config.nyx.apps.git;
in
{
  options.nyx.apps.git = {
    enable = lib.mkEnableOption "Git version control";

    name = lib.mkOption {
      type = lib.types.str;
      default = config.nyx.flake.user;
      description = "Name for Git commits";
    };

    email = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Email address for Git commits";
    };

    globalIgnores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ ".direnv/" "result" ];
      description = "Machine-global gitignore patterns, applied to every repo and never committed.";
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
      ignores = cfg.globalIgnores;

      settings = {
        alias.ignore-local = ''!sh -c 'printf "%s\n" "$@" >> "$(git rev-parse --git-dir)/info/exclude"' _'';
        user = {
          name = cfg.name;
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
      enableDefaultConfig = false;
      matchBlocks."github.com" = {
        identityFile = cfg.signing.keyFile |> lib.removeSuffix ".pub";
        identityAgent = "none";
        identitiesOnly = true;
      };
    };

    nyx.persistence.home.directories = [ ".ssh" ];
  };
}
