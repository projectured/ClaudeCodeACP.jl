# ClaudeCodeACP.jl

An agent of the [Agent Client Protocol](https://agentclientprotocol.com) (ACP)
in Julia that runs the Claude Code program that you installed and signed in. It
is not made by Anthropic.

[![CI](https://github.com/projectured/ClaudeCodeACP.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/projectured/ClaudeCodeACP.jl/actions/workflows/CI.yml)

An editor that speaks ACP, such as ProjecturEd, Zed or a plugin of another
editor, starts the program `claude-code-acp` and talks to it on its standard
input and output. For each session, the agent starts one `claude -p` process,
the documented headless mode of Claude Code, and turns what Claude Code does
into the updates of the session:

- the text of the answer and the summary of the thinking, as they stream;
- each tool call, with its title, its kind, its file, and a diff for an edit;
- the plan, from the task list of Claude Code;
- the commands, the usage of the context and the cost estimate;
- the title of the session, from the first prompt that it gets.

Before Claude Code runs a tool that needs your word, the agent asks the editor,
which shows you the question with "Allow", "Always allow" and "Reject". A cancel
in the editor stops the turn. The mode, the model and the effort are options of
the session.

The agent needs no Node.js and no API key. It uses the sign-in of Claude Code
and reads no credential.

## Install

You need Claude Code, signed in: run `claude auth login` once, or sign in with
`claude` in a terminal.

ClaudeCodeACP is in the registry
[`ProjecturedRegistry`](https://github.com/projectured/ProjecturedRegistry), not in
the General registry. Add both registries once, and then install the program as
a Pkg app (Julia 1.12 or later):

```
pkg> registry add General
pkg> registry add https://github.com/projectured/ProjecturedRegistry
pkg> app add ClaudeCodeACP
```

Pkg puts the program `claude-code-acp` in `~/.julia/bin`; add that folder to your
`PATH`.

## Use it in an editor

Give your editor the command `claude-code-acp` as an ACP agent. For example, in
Zed:

```json
{
  "agent_servers": {
    "Claude Code (Julia)": { "command": "claude-code-acp", "args": [] }
  }
}
```

The program takes these arguments:

| Argument | Effect |
| --- | --- |
| `--strict-mcp-config` | Claude Code gets only the MCP servers of the editor, and not your own MCP servers and connectors. |
| `--claude=PATH` | The program of Claude Code, when it is not `claude` on the `PATH`. |
| `--login` | Run `claude auth login` in this terminal. An editor runs it for its sign-in button. |

A session loads your configuration of Claude Code, as `claude` does in a
terminal: your settings, skills, commands and `CLAUDE.md` files, and, without
`--strict-mcp-config`, your MCP servers and claude.ai connectors too.

## Use it from Julia

The agent is an `AgentHandler` of
[AgentClientProtocol.jl](https://github.com/projectured/AgentClientProtocol.jl), so
an editor in Julia can host it in its own process, on two streams:

```julia
using ClaudeCodeACP, AgentClientProtocol

to_agent, to_editor = Base.BufferStream(), Base.BufferStream()
@async serve_agent(; input = to_agent, output = to_editor)
connection = open_connection(MyClient(), to_editor, to_agent)
```

## How it works

```
editor ──ACP──▶ claude-code-acp ──stream-json──▶ claude -p   (one process for each session)
                      │
                      └── MCP server on 127.0.0.1: the permission tool
```

- Each session runs `claude -p --input-format stream-json --output-format
  stream-json --include-partial-messages`, with `--session-id` for a new
  session and `--resume` for a session that the editor resumes. A change of an
  option starts it again with `--resume` and the new flag.
- The agent passes the setting `showThinkingSummaries` and, when `claude` takes
  it, the flag `--thinking-display summarized`, so the thinking of a recent
  model streams as text. The help of `claude` does not list that flag, so the
  agent checks it once with a wrong value, which a `claude` that knows the flag
  refuses.
- The agent serves a small MCP server on the loopback address, and gives Claude
  Code its tool with `--permission-prompt-tool`. Each session has its own
  random bearer secret for it.
- A cancel sends the interrupt message of the stream when Claude Code offers
  it, and `SIGINT` else.
- A `Read` of a text file goes to the editor as a resource: the text as it is in
  the file, without the numbers of its lines, its `file://` uri, and the media
  type of its extension, so an editor can show a Markdown file or Julia code as
  more than text.
- An editor can add text to the system prompt of a session, such as what the
  editor is and how to use its tools, in the `_meta` of `session/new` as
  `claudeCode.options.systemPrompt.append`, the key that the Claude agents of
  ACP read. The agent passes it with `--append-system-prompt-file`.

## Licence

MIT: see [LICENSE](LICENSE). Claude Code is a product of Anthropic, with its own
terms; this agent only runs the program that you installed.
