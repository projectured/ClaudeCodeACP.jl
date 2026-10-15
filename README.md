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
- the plan, from the task list and the to-do list of Claude Code;
- the commands, the usage of the context and the cost estimate;
- the title of a new session, from its first prompt. A resumed session gets no
  new title, so the editor keeps the title that it has.

Before Claude Code runs a tool that needs your word, the agent asks the editor,
which shows you the question with "Allow", "Always allow" and "Reject". A cancel
in the editor stops the turn. The mode, the model and the effort are options of
the session.

A message that you write while Claude works goes into the turn that runs,
through the extension method `_session/steering`, which the agent advertises as
`_meta.steering.supported`: Claude reads it at its next step, or in a turn of
its own just after the one that runs, and the prompt ends after that turn.

When Claude asks you a question with its tool `AskUserQuestion`, an editor that
shows forms (`clientCapabilities.elicitation.form`) gets the questions as one
form, `elicitation/create`: a choice for each question, of one option or of
several, and a text field for an answer in your own words. Your answers go back
to Claude. An editor that shows no form gets no such question: Claude then asks
in its text.

The agent needs no Node.js and no API key. It uses the sign-in of Claude Code
and reads no credential. To an editor that can run a sign-in in a terminal, it
names the sign-in `claude-login`, which runs `claude-code-acp --login`. An editor
that runs the agent in its own process runs `make_login_command()` for it. The ACP
request `logout` runs `claude auth logout`, and the next prompt of each session
then asks for a sign-in.

## The work of Claude

Some parts of ACP are not stable yet. The agent sends each of them only to an
editor that advertises it in `initialize`.

- **Subagents** (`clientCapabilities.subagents`). Each subagent of Claude is a
  child session. The agent announces it on its parent session with
  `subagent_update`. The session id of the child is the task id of the subagent
  in Claude Code. The prompt of the subagent comes as a user message of the
  child session. Its text, its thinking and its tool calls come in the child
  session. Its progress keeps it running, and its end makes it idle. A
  `session/cancel` of the child session stops the subagent.
- **Plans** (`clientCapabilities.plan`). A plan has an id. The steps of the
  task tools and of `TodoWrite` come as `plan_update` of the type `items`, with
  the id `tasks`. The plan of the plan mode comes as `plan_update` of the type
  `markdown`, with the id `plan-mode`. Another editor gets the steps as the
  `plan` of ACP version 1.
- **Notices** (`clientCapabilities.session.notices`). A retry of a request to
  the API comes as a notice. A fallback to another model comes as a notice.
- **Compactions** (`clientCapabilities.session.compaction`). A compaction of
  the conversation comes as `compaction_update`.
- **Background tasks** (an object at `clientCapabilities._meta.backgroundTasks`).
  A background task is work that runs after the call that started it, such as
  a command with `run_in_background`. The agent advertises
  `_meta.backgroundTasks.supported`. Each change of a background task comes in
  the extension notification `_session/background_task`. Its params are
  `sessionId`, `taskId`, `kind`, `title`, `status`, `startTime` and `canStop`,
  and, when they are known, `toolCallId`, `subagentId`, `outputUri`, `summary`
  and `endTime`. The status is `running`, `completed`, `failed` or `stopped`.
  The times are milliseconds since 1970. The extension request
  `_session/stop_background_task`, with `sessionId` and `taskId`, stops a task
  that runs.

The `_meta.claudeCode` of an entry of the plan holds `taskId`, `description`,
`activeForm` and `blockedBy`, the ids of the steps that block it. The
`_meta.claudeCode` of a `subagent_update` holds `usage` (`totalTokens`,
`toolUses` and `durationMs`), `lastToolName` and `summary`. Each holds only the
keys that Claude Code gives.

When `claude` ends or starts again for a new option, the work that runs in it
ends too. Each subagent that runs becomes idle, with the stop reason
`cancelled`. Each background task that runs gets the status `stopped`, or
`failed` when `claude` ended by itself.

The first prompt after each start of `claude` sends a `session_info_update`
whose `_meta.processId` is the process id of that `claude`.

The agent reads what `claude` writes also between two prompts. When a
background task ends after a turn, `claude` starts a turn by itself. That turn
reaches the editor at once, as updates of the session.

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
- `claude` gives each MCP server two minutes to connect (`MCP_TIMEOUT=120000`),
  unless the environment sets `MCP_TIMEOUT`. The servers of an editor that hosts
  the agent run in the process of the editor, which can be slow to answer its
  first request, and a server that misses the time is gone for the session.
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
