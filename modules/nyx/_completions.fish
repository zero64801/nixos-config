set -l commands switch boot test build update pin persist clean diff repl help

complete -c nyx -f

complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a switch -d "Rebuild and activate now"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a boot -d "Rebuild and activate on next boot"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a test -d "Rebuild and activate without a boot entry"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a build -d "Build without activating"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a update -d "Update flake inputs (pin aware)"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a pin -d "Manage flake input pins"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a persist -d "Manage impermanence paths"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a clean -d "Delete old generations and collect garbage"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a diff -d "Diff built system against the running one"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a repl -d "Open nix repl with the flake loaded"
complete -c nyx -n "not __fish_seen_subcommand_from $commands" -a help -d "Show help"

complete -c nyx -n "__fish_seen_subcommand_from pin" -a "status freeze pin unpin update restore check diff why set-reason history config help"
complete -c nyx -n "__fish_seen_subcommand_from persist" -a "list add remove junk config help"
complete -c nyx -n "__fish_seen_subcommand_from clean" -l older-than -d "Age threshold for generation deletion"
