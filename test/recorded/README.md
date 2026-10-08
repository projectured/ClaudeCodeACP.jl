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
