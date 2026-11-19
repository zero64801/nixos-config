# The lab's agent and what serves an agent

This folder is everything in `vm-lab` that exists for an AI agent.
Without it `vm-lab` has no `--agent` and no `guest-mcp`, and nothing else changes.
It plugs into the lab through two of its options: `my.virtualisation.lab.modes` for the agent and `my.virtualisation.lab.tools` for `guest-mcp`.

## vm-lab-agent

```
vm-lab-agent [--join] DOMAIN [ARGUMENT...]
vm-lab-agent --token
```

`vm-lab-agent DOMAIN`, the same as `vm-lab --agent DOMAIN`, starts Claude Code inside the lab with control of the guest.
It is for a guest whose output should not reach a session that can edit the user's repositories.
It is off until `my.virtualisation.lab.agent.enable` is set, and it needs the lab to have a sandbox.

- Its token is its own: `claude setup-token` prints one and `vm-lab-agent --token` stores it in `agent.tokenFile`.
- Its way out is `host-gate`, which lets through the two hosts Claude Code needs and nothing else, by way of `agent.proxy` when that is set.
- What it is told about the lab is `_agent.md`, which reaches it from the Nix store.
  It sees nothing of the Claude Code settings of the user who starts it.
- Its MCP servers are the ones the start folder's `.mcp.json` runs in this guest through `guest-mcp`.
- Its conversations are kept in `~/.local/state/vm-lab-agent`, which no other lab sees.

## guest-mcp

`guest-mcp` comes with this folder whenever the lab is on, with or without the agent, since a session outside the lab uses it too.

`guest-mcp PROGRAM ARGS` starts a program in the guest and stands in for it on this side.
Whatever starts `guest-mcp` talks to it over standard input and output as to a server of its own, which is how an MCP server that lives in the guest is used from the host.
It takes `--as-user`, `--user`, `--elevated`, `--cwd` and `--env NAME=VALUE`.

The program runs as a job that reads what is added to one file and answers into another.
Each line for it goes in with one short command that then waits for the answer and brings it back.
So every request shows in the session's log, word for word up to the length of a log line.
A call costs about a tenth of a second on top of what the program takes.

Each line of the program's is read as JSON on this side and written out anew: whole, bounded in size and depth, and without the characters a terminal acts on.
A line that is no JSON message is left out.
What the messages say is still the guest's.

When `guest-mcp` is ended by force, the program may stay behind in the guest.
It is a job like any other, so `guest-job status` shows it and `guest-job stop` ends it.

## Tests

```
nix build --no-link -L .#tests.agent.agent
nix build --no-link -L .#tests.agent.guest-mcp
```

The first builds the agent for a made up system and plays a guest whose program answers `guest-mcp` as badly as it can.
The second boots the machine and the guest that vm-inspect's tests share, and talks to a program in that guest through `guest-mcp`.
