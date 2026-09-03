set -l commands status freeze pin unpin update restore check diff why set-reason history config sources help

complete -c pin -f
complete -c pin -n "not __fish_seen_subcommand_from $commands" -a "$commands"
complete -c pin -n "__fish_seen_subcommand_from sources" -a "ls update"
