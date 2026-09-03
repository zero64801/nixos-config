set -l commands list add remove junk config help

complete -c persist -f
complete -c persist -n "not __fish_seen_subcommand_from $commands" -a "$commands"
