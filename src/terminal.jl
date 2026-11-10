# The Bash tool of the agent, for a client that offers terminals: the MCP server
# of the agent serves `Bash`, with the inputs of the own tool of Claude Code,
# and two tools for a command in the background, and each runs its command in
# a terminal of the client. `claude` then runs without its own `Bash`, so each
# command of Claude runs in the editor, where the person sees it.

# The tools, as the server names them and as `claude` calls them.
const BASH_TOOL = "Bash"
const BASH_OUTPUT_TOOL = "BashOutput"
const KILL_BASH_TOOL = "KillBash"
const BASH_TOOL_NAME = "mcp__$(PERMISSION_SERVER_NAME)__$(BASH_TOOL)"
const BASH_OUTPUT_TOOL_NAME = "mcp__$(PERMISSION_SERVER_NAME)__$(BASH_OUTPUT_TOOL)"
const KILL_BASH_TOOL_NAME = "mcp__$(PERMISSION_SERVER_NAME)__$(KILL_BASH_TOOL)"

# The own tools of `claude` that the Bash tool of the agent replaces.
const REPLACED_TOOLS = ("Bash",)

# The time of a command in the foreground, in milliseconds: its default and its
# most, as for the own `Bash` of `claude`.
const DEFAULT_COMMAND_MILLISECONDS = 120_000
const MAX_COMMAND_MILLISECONDS = 600_000

# The most bytes of output that a tool answers. The client cuts the output from
# its start.
const OUTPUT_BYTE_LIMIT = 30_000

# The time in milliseconds that `claude` gives each call of the MCP server of the
# agent, as the `timeout` of the server, when the client offers terminals: the
# limit of a call that `claude` names by default. Without it, `claude` 2.1.309
# ends a call of an HTTP server that gives no answer in a minute, and a command
# in the foreground runs up to ten.
const BASH_CALL_MILLISECONDS = 100_000_000

"""
    make_bash_tools() -> Vector{Dict{String,Any}}

The tools `Bash`, `BashOutput` and `KillBash`, as `tools/list` names them. Each
is always in the prompt of Claude, through `_meta."anthropic/alwaysLoad"`, so
Claude needs no tool search to find it.
"""
function make_bash_tools()
    id_schema = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}(
        "bash_id" => Dict{String,Any}("type" => "string", "description" => "The id that Bash answered.")),
        "required" => Any["bash_id"])
    meta = Dict{String,Any}("anthropic/alwaysLoad" => true)
    Dict{String,Any}[
        Dict{String,Any}("name" => BASH_TOOL, "_meta" => meta,
            "description" => "Runs a bash command in a terminal of the editor, where the person sees it, and " *
                "answers its output and its exit code. Each command starts in the folder of the session, so a `cd` " *
                "does not carry to the next one. A command that runs longer than `timeout` is stopped. With " *
                "`run_in_background`, the answer is the id of the command, at once: read its output with " *
                "$(BASH_OUTPUT_TOOL_NAME), and stop it with $(KILL_BASH_TOOL_NAME).",
            "inputSchema" => Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}(
                "command" => Dict{String,Any}("type" => "string", "description" => "The command to run."),
                "timeout" => Dict{String,Any}("type" => "number",
                    "description" => "The most time of the command in milliseconds, at most " *
                                     "$(MAX_COMMAND_MILLISECONDS); $(DEFAULT_COMMAND_MILLISECONDS) when it is not given."),
                "description" => Dict{String,Any}("type" => "string",
                                                  "description" => "What the command does, in a few words."),
                "run_in_background" => Dict{String,Any}("type" => "boolean",
                                                        "description" => "Run the command in the background.")),
                "required" => Any["command"])),
        Dict{String,Any}("name" => BASH_OUTPUT_TOOL, "_meta" => meta, "inputSchema" => id_schema,
            "description" => "Answers the output so far of a command that runs in the background, and its exit " *
                             "code once it ended."),
        Dict{String,Any}("name" => KILL_BASH_TOOL, "_meta" => meta, "inputSchema" => id_schema,
            "description" => "Stops a command that runs in the background, and frees its id.")]
end

"""
    call_bash_tool!(agent, session, name, arguments, tool_use_id) -> Union{Dict,Nothing}

The result of a call of the tool `name` of the server, as `tools/call` answers
it, or `nothing` for a tool that is not one of [`make_bash_tools`](@ref). Each
runs through the terminal requests of the client:

- `Bash` creates a terminal that runs `bash -c` with the command, in the folder
  of the session. In the foreground, it waits for the end of the command, kills
  it at its timeout, at a cancel of the prompt and at a close of the session,
  reads its output and releases the terminal. In the background, it answers the
  id of the terminal at once, and the session holds the terminal.
- `BashOutput` answers the output and the exit status of a terminal that the
  session holds.
- `KillBash` kills and releases a terminal that the session holds.

The card of the tool call `tool_use_id` of Claude gets the terminal, so the
client shows the command as it runs.
"""
function call_bash_tool!(agent::ClaudeCodeAgent, session::ClaudeSession, name::String,
                         arguments::Dict{String,Any}, tool_use_id::String)
    name in (BASH_TOOL, BASH_OUTPUT_TOOL, KILL_BASH_TOOL) || return nothing
    connection = agent.connection
    connection === nothing && return _make_text_result("No editor is connected, so no command can run."; is_error = true)
    try
        name == BASH_TOOL && return _run_bash_command!(agent, session, connection, arguments, tool_use_id)
        terminal_id = string(get(arguments, "bash_id", ""))
        is_held = lock(() -> terminal_id in session.terminals, session.lock)
        is_held || return _make_text_result("No command `$(terminal_id)` runs in the background of this session.";
                                            is_error = true)
        name == BASH_OUTPUT_TOOL && return _read_bash_output(connection, session, terminal_id)
        _kill_bash_command!(connection, session, terminal_id)
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
        reason = exception isa ACP.ProtocolException ? exception.message : "its connection failed."
        _make_text_result("The editor did not run the command: " * reason; is_error = true)
    end
end

function _run_bash_command!(agent::ClaudeCodeAgent, session::ClaudeSession, connection::ACP.Connection,
                            arguments::Dict{String,Any}, tool_use_id::String)
    command = get(arguments, "command", nothing)
    command isa AbstractString && !isempty(strip(command)) ||
        return _make_text_result("Bash needs a `command`."; is_error = true)
    timeout = get(arguments, "timeout", nothing)
    milliseconds = timeout isa Real && timeout > 0 ? min(_read_count(timeout), MAX_COMMAND_MILLISECONDS) :
                   DEFAULT_COMMAND_MILLISECONDS
    # A command of Claude is a line of bash, and a terminal runs a program with
    # its arguments, so the line goes to bash as one argument.
    terminal_id = ACP.send_request!(connection, ACP.CreateTerminalRequest(
        session_id = session.id, command = "bash", args = ["-c", String(command)], cwd = session.directory,
        output_byte_limit = OUTPUT_BYTE_LIMIT)).terminal_id
    if get(arguments, "run_in_background", false) === true
        lock(() -> push!(session.terminals, terminal_id), session.lock)
        _send_terminal_content!(agent, session, tool_use_id, terminal_id)
        return _make_text_result("The command runs in the background with the id `$(terminal_id)`. Read its output " *
                                 "with $(BASH_OUTPUT_TOOL_NAME), and stop it with $(KILL_BASH_TOOL_NAME).")
    end
    _send_terminal_content!(agent, session, tool_use_id, terminal_id)
    try
        ended, reason = _wait_for_command!(connection, session, terminal_id, milliseconds / 1000)
        ended isa Exception && throw(ended)
        output = ACP.send_request!(connection, ACP.TerminalOutputRequest(session_id = session.id,
                                                                         terminal_id = terminal_id))
        status = ended === nothing ? output.exit_status : ended
        ending = reason === :timeout ? "The command was stopped after $(milliseconds) ms." :
                 reason === :stopped ? "The command was stopped." :
                 _is_failed_exit(status) ? _describe_exit_status(status.exit_code, status.signal) : nothing
        text = _format_terminal_output(output)
        _make_text_result(ending === nothing ? text : _append_line(text, ending); is_error = ending !== nothing)
    finally
        _release_terminal_quietly!(connection, session, terminal_id)
    end
end

# Wait for the end of the command of a terminal, at most `seconds`. The command
# is killed at that time, and at a cancel of the prompt in which it started or
# a close of the session. Answers the exit status, or the error of the wait, or
# `nothing` when no end came after the kill; and why the agent killed it,
# `:timeout` or `:stopped`, or `nothing`.
function _wait_for_command!(connection::ACP.Connection, session::ClaudeSession, terminal_id::String, seconds::Real)
    is_in_prompt = lock(() -> session.is_prompting && !session.is_cancelled, session.lock)
    is_stopped() = lock(() -> session.is_closed || is_in_prompt && session.is_cancelled, session.lock)
    waiter = @async try
        ACP.send_request!(connection, ACP.WaitForTerminalExitRequest(session_id = session.id, terminal_id = terminal_id))
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
        exception
    end
    timedwait(() -> istaskdone(waiter) || is_stopped(), Float64(seconds); pollint = 0.05)
    reason = istaskdone(waiter) ? nothing : is_stopped() ? :stopped : :timeout
    if reason !== nothing
        ACP.send_request!(connection, ACP.KillTerminalRequest(session_id = session.id, terminal_id = terminal_id))
        timedwait(() -> istaskdone(waiter), 10.0)
    end
    (istaskdone(waiter) ? fetch(waiter) : nothing, reason)
end

function _read_bash_output(connection::ACP.Connection, session::ClaudeSession, terminal_id::String)
    output = ACP.send_request!(connection, ACP.TerminalOutputRequest(session_id = session.id, terminal_id = terminal_id))
    status = output.exit_status
    _make_text_result(_append_line(_format_terminal_output(output),
        status === nothing ? "The command runs." : _describe_exit_status(status.exit_code, status.signal)))
end

function _kill_bash_command!(connection::ACP.Connection, session::ClaudeSession, terminal_id::String)
    lock(() -> delete!(session.terminals, terminal_id), session.lock)
    try
        ACP.send_request!(connection, ACP.KillTerminalRequest(session_id = session.id, terminal_id = terminal_id))
    finally
        _release_terminal_quietly!(connection, session, terminal_id)
    end
    _make_text_result("The command `$(terminal_id)` is stopped.")
end

function _release_terminal_quietly!(connection::ACP.Connection, session::ClaudeSession, terminal_id::String)
    try
        ACP.send_request!(connection, ACP.ReleaseTerminalRequest(session_id = session.id, terminal_id = terminal_id))
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
    end
    nothing
end

# The terminals that a closed session still holds go back to the client, which
# ends their commands. The close does not wait for the answers.
function _release_session_terminals!(agent::ClaudeCodeAgent, session::ClaudeSession)
    terminals = lock(() -> (terminals = collect(session.terminals); empty!(session.terminals); terminals), session.lock)
    connection = agent.connection
    connection === nothing && return nothing
    for terminal_id in terminals
        try
            ACP.start_request!(connection, ACP.ReleaseTerminalRequest(session_id = session.id, terminal_id = terminal_id))
        catch exception
            exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
        end
    end
    nothing
end

# The terminal of the tool call `tool_use_id` goes into the card of the call: at
# once, when the translation knows the call, and else with the call itself when
# its event comes. The send lock keeps it in the order of the translation.
function _send_terminal_content!(agent::ClaudeCodeAgent, session::ClaudeSession, tool_use_id::String,
                                 terminal_id::String)
    isempty(tool_use_id) && return nothing
    lock(session.send_lock) do
        session_id = lock(session.lock) do
            translation = session.translation
            translation.state.terminals[tool_use_id] = terminal_id
            haskey(translation.state.tool_calls, tool_use_id) ? translation.session_id :
                _find_subagent_id(translation, tool_use_id)
        end
        session_id === nothing || _send_messages_quietly!(agent, Pair{String,Any}[session_id => ACP.ToolCallUpdate(
            tool_call_id = tool_use_id, content = ACP.ToolCallContent[ACP.Terminal(terminal_id = terminal_id)])])
    end
    nothing
end

# The output of a terminal as the text of a result: a note when the client cut
# its start, and a note when it is empty.
function _format_terminal_output(output::ACP.TerminalOutputResponse)
    text = isempty(output.output) ? "(no output)" : output.output
    output.truncated ? "[The start of the output is cut.]\n" * text : text
end

_append_line(text::String, line::String) = endswith(text, '\n') ? text * line : text * "\n" * line

# Whether a command ended with a signal or an exit code that is not 0.
_is_failed_exit(status) = status !== nothing &&
    (status.signal isa AbstractString && !isempty(status.signal) || something(status.exit_code, 0) != 0)

_describe_exit_status(exit_code, signal) =
    signal isa AbstractString && !isempty(signal) ? "The command ended by the signal $(signal)." :
    exit_code === nothing ? "The command ended." : "Exit code $(exit_code)"

_make_text_result(text::String; is_error::Bool = false) = Dict{String,Any}(
    "content" => Any[Dict{String,Any}("type" => "text", "text" => text)], "isError" => is_error)
