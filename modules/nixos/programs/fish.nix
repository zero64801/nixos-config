{
  pkgs,
  config,
  ...
}:

let
  inherit (config.networking) hostName;
  rebuildCommand = "sudo nixos-rebuild --flake ~/nixos#${hostName}";

  rosepine-fzf = [
    "fg:#908caa"
    "bg:-1"
    "hl:#ebbcba"
    "fg+:#e0def4"
    "bg+:#26233a"
    "hl+:#ebbcba"
    "border:#403d52"
    "header:#31748f"
    "gutter:#191724"
    "spinner:#f6c177"
    "info:#9ccfd8"
    "pointer:#c4a7e7"
    "marker:#eb6f92"
    "prompt:#908caa"
  ];

  fzf-options = builtins.concatStringsSep " " (
    builtins.map (option: "--color=" + option) rosepine-fzf
  );
in
{
  users.users.root.shell = pkgs.fish;
  documentation.man.generateCaches = false;

  programs.fish = {
    enable = true;
    useBabelfish = true;
    generateCompletions = false;

    shellAbbrs = {
      # Nix commands
      snw = rebuildCommand;
      nsh = "nix shell nixpkgs#";
      nrn = "nix run nixpkgs#";

      # Git commands
      gaa = "git add --all";
      ga = "git add";
      gc = "git commit";
      gcm = "git commit -m";
      gca = "git commit --amend";
      gcp = "git cherry-pick";
      grs = "git restore --staged";
      grsa = "git restore --staged .";
      gr = "git restore";
      gra = "git restore .";
      gs = "git status";
      gd = "git diff";
      gdw = "git diff --word-diff";
      gds = "git diff --staged";
      gdh = "git diff HEAD~1";
      glg = "git log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(auto)%d%C(reset)' --all";
      gl = "git log";

      # Systemctl commands
      sy = "systemctl";
      sya = "systemctl start";
      syo = "systemctl stop";
      syr = "systemctl restart";
      su = "systemctl --user";
      sua = "systemctl --user start";
      suo = "systemctl --user stop";
      sur = "systemctl --user restart";
    };

    shellAliases = {
      snow = rebuildCommand;
      snowboot = "${rebuildCommand} boot";
      snowfall = "${rebuildCommand} switch";
      snowtest = "${rebuildCommand} test";
      ls = "eza --icons --group-directories-first -1";
    };

    interactiveShellInit = ''
      set sponge_purge_only_on_exit true
      set fish_greeting
      set fish_cursor_insert line blink
      set -Ux FZF_DEFAULT_OPTS "${fzf-options}"
      fish_vi_key_bindings

      function fish_user_key_bindings
        bind --mode insert alt-c 'cdi; commandline -f repaint'
        bind --mode insert alt-f 'fzf-file-widget'
      end

      # Hydro prompt configuration
      set -g hydro_symbol_start ""
      set -U hydro_symbol_git_dirty "*"
      set -U fish_prompt_pwd_dir_length 0

      function fish_mode_prompt; end

      function update_nshell_indicator --on-variable IN_NIX_SHELL
        if test -n "$IN_NIX_SHELL"
          set -g hydro_symbol_start "impure "
        else
          set -g hydro_symbol_start ""
        end
      end
      update_nshell_indicator

      # Get store path for a given executable
      function store_path -a package_name
        which $package_name 2>/dev/null | path resolve | read -l package_path
        if test -n "$package_path"
          echo (path dirname $package_path | path dirname)
        end
      end
    '';
  };

  programs = {
    zoxide = {
      enable = true;
      enableFishIntegration = true;
      flags = [ "--cmd cd" ];
    };
    direnv.enableFishIntegration = true;
    command-not-found.enable = false;
    fzf.keybindings = true;
  };

  environment.systemPackages = with pkgs; [
    fishPlugins.done
    fishPlugins.sponge
    fishPlugins.hydro
    eza
    fish-lsp
  ];
}
