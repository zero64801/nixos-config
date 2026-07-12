{ config, lib, pkgs, ... }:

let
  cfg = config.nyx.apps.fish;

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
  options.nyx.apps.fish.enable = lib.mkEnableOption "Fish shell";

  config = lib.mkIf cfg.enable {
    users.users.root.shell = pkgs.fish;
    documentation.man.cache.enable = false;

    programs.fish = {
      enable = true;
      useBabelfish = true;
      generateCompletions = false;

      shellAbbrs = {
        ns = "nyx switch";
        nu = "nyx update";
        nsh = "nix shell nixpkgs#";
        nrn = "nix run nixpkgs#";

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
        ls = "eza --icons --group-directories-first -1";
      };

      interactiveShellInit = ''
        set sponge_purge_only_on_exit true
        set fish_greeting
        set fish_cursor_insert line blink
        set -gx FZF_DEFAULT_OPTS "${fzf-options}"
        fish_vi_key_bindings

        function fish_user_key_bindings
          bind --mode insert alt-c 'cdi; commandline -f repaint'
          bind --mode insert alt-f 'fzf-file-widget'
        end

        set -g hydro_symbol_start ""
        set -gx hydro_symbol_git_dirty "*"
        set -gx fish_prompt_pwd_dir_length 0

        function fish_mode_prompt; end

        function update_nshell_indicator --on-variable IN_NIX_SHELL
          if test -n "$IN_NIX_SHELL"
            set -g hydro_symbol_start "impure "
          else
            set -g hydro_symbol_start ""
          end
        end
        update_nshell_indicator

        function store_path -a package_name
          which $package_name 2>/dev/null | path resolve | read -l package_path
          if test -n "$package_path"
            echo (path dirname $package_path | path dirname)
          end
        end

        function __pad_device_xml
          printf '%s\n' '<hostdev mode="subsystem" type="usb" managed="yes">
            <source><vendor id="0x045e"/><product id="0x028e"/></source>
          </hostdev>'
        end

        function __pad_state_file
          if set -q XDG_RUNTIME_DIR
            echo "$XDG_RUNTIME_DIR/pad-last-domain"
          else
            echo "/tmp/pad-last-domain-$USER"
          end
        end

        function pad-on -a domain --description "Attach gamepad to VM domain"
          if test -z "$domain"
            echo "Usage: pad-on <domain>" >&2
            return 2
          end

          __pad_device_xml | sudo virsh attach-device "$domain" /dev/stdin --live
          set -l attach_status $status

          if test $attach_status -eq 0
            set -l state_file (__pad_state_file)
            mkdir -p (path dirname "$state_file")
            printf '%s\n' "$domain" > "$state_file"
          end

          return $attach_status
        end

        function pad-off --description "Detach gamepad from last VM domain used by pad-on"
          set -l state_file (__pad_state_file)

          if not test -s "$state_file"
            echo "No previous pad-on domain recorded. Run pad-on <domain> first." >&2
            return 1
          end

          read -l domain < "$state_file"
          if test -z "$domain"
            echo "No previous pad-on domain recorded. Run pad-on <domain> first." >&2
            return 1
          end

          __pad_device_xml | sudo virsh detach-device "$domain" /dev/stdin --live
          set -l detach_status $status

          if test $detach_status -eq 0
            rm -f "$state_file"
          end

          return $detach_status
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

    nyx.persistence.home.directories = [
      ".local/share/fish"
    ];
  };
}
