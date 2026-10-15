# Recorded streams

Each file holds the events that `claude -p --output-format stream-json` 2.1.285
wrote for one turn, with the model `haiku`, in an empty folder. They were
recorded on 2026-10-08 and then cleaned:

- the `rate_limit_event` lines are left out;
- `system/init` keeps only built-in tools and three built-in commands, and no
  skills, plugins, agents of a person or paths of a machine;
- the folder of the recording is `/work`;
- each thinking signature is `<signature>`.

The files hold no account data. The marker `{"type": "_wait_for_interrupt"}` in
`interrupted.jsonl` is where the recording sent the interrupt message; the fake
`claude` of the tests waits there for the interrupt of the agent.

Claude Code 2.1.286 wrote the next four files on 2026-10-15, with the model
`haiku`, in an empty folder that holds at most three small files, with
`--include-partial-messages --replay-user-messages`, `--setting-sources project`
and `--strict-mcp-config` with no MCP server. They are cleaned the same way,
and `system/init` also lacks `memory_paths`, `messaging_socket_path` and
`scratchpad_path`. The folder of the tool output files is `/tmp/claude/work`.

- `subagent.jsonl` holds two turns: one `Agent` call that starts a subagent in
  the background (`task_started`, `task_progress`, `task_updated`,
  `task_notification`, and the `assistant` and `user` events of the subagent
  with a `parent_tool_use_id`), the `result` of the first turn, and a second
  turn (`init`, text, `result`) that `claude` starts by itself when the
  subagent ends.
- `background-task.jsonl` holds two turns: two `Bash` calls with
  `run_in_background`, a `TaskStop` call for the second one, the
  `task_notification` of both, the first `result`, and a second turn that
  `claude` starts by itself when the first command ends and that reads its
  output file.
- `plan-steps.jsonl` holds one turn with `TaskCreate` three times and
  `TaskUpdate` three times (one with `addBlockedBy`). It was recorded with
  `CLAUDE_CODE_ENABLE_TASKS=1`: without it `claude -p` has `TodoWrite` and no
  `TaskCreate`.
- `plan-mode.jsonl` holds one turn with `--permission-mode plan` and
  `--permission-prompt-tool stdio`, which `claude -p` needs to offer
  `ExitPlanMode`. The recording holds the `control_request` for `ExitPlanMode`,
  the `control_response` that denies it ("The plan is not approved."), which the
  recording sent, and the rest of the turn.
