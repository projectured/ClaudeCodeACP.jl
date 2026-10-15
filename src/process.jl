# The `claude` program in print mode, with stream-json on its standard input and
# output: one process for each session of the agent.

"""
    ClaudeProcess

One `claude -p` process: the stream that takes its messages, and the events
that it writes, one JSON object on each line. A task reads the events into
`events`; the last event is `{"type": "process_exit"}`. A `control_response` to
a control request that waits for its answer goes to `waiting_answers`, by its
request id, and not to `events`. `capabilities` holds the capabilities of its
last `system/init`.
"""
mutable struct ClaudeProcess
    process::Union{Nothing,Base.Process}
    process_id::Int32
    input::IO
    output::IO
    events::Channel{Dict{String,Any}}
    waiting_answers::Dict{String,Channel{Dict{String,Any}}}
    answer_lock::ReentrantLock
    capabilities::Vector{String}
    write_lock::ReentrantLock
    is_closed::Bool
    is_ending::Bool
    is_reader_done::Bool
    is_exit_reported::Threads.Atomic{Bool}
end

# The variables of the environment that tie a process to a session of Claude
# Code that runs it. A `claude` that the agent starts belongs to no such session,
# so it does not get them.
const PARENT_SESSION_VARIABLES = ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_AGENT_SDK_VERSION")

# The time in milliseconds that `claude` gives each MCP server to connect, when
# the environment does not set `MCP_TIMEOUT`: two minutes. The MCP servers of an
# editor that hosts the agent run in the process of the editor, which can be slow
# to answer its first request, and a server that misses the time of `claude`
# (30 s) is gone for the whole session.
const MCP_TIMEOUT_MILLISECONDS = "120000"

function make_claude_environment()
    environment = Dict{String,String}(filter(pair -> !(first(pair) in PARENT_SESSION_VARIABLES), ENV))
    get!(environment, "MCP_TIMEOUT", MCP_TIMEOUT_MILLISECONDS)
    environment
end

"""
    open_claude_process(streams::Tuple{IO,IO}; capabilities) -> ClaudeProcess
    open_claude_process(command::Cmd; capabilities) -> ClaudeProcess

Talk to `claude` on two streams, `(input, output)`, or start `command` in a
process group of its own. Each line of its standard error goes to the standard
error of the agent. `capabilities` are the capabilities that an earlier process
of the same program announced, which count until the first `system/init`.
"""
function open_claude_process(streams::Tuple{IO,IO}; process::Union{Nothing,Base.Process} = nothing,
                             capabilities::Vector{String} = String[])
    input, output = streams
    claude = ClaudeProcess(process, process === nothing ? Int32(0) : Int32(getpid(process)),
                           input, output, Channel{Dict{String,Any}}(Inf),
                           Dict{String,Channel{Dict{String,Any}}}(), ReentrantLock(), copy(capabilities),
                           ReentrantLock(), false, false, false, Threads.Atomic{Bool}(false))
    errormonitor(@async _read_claude_events!(claude))
    claude
end

function open_claude_process(command::Cmd; capabilities::Vector{String} = String[])
    errors = Pipe()
    command = Cmd(command; detach = true, env = make_claude_environment())
    process = open(pipeline(command; stderr = errors), "r+")
    close(errors.in)
    errormonitor(@async _forward_claude_errors!(errors))
    claude = open_claude_process((process.in, process.out); process, capabilities)
    # A child of `claude` can keep its output open after it ends, so the end of
    # the process counts too, after the reader had time for the last events.
    errormonitor(@async begin
        wait(process)
        timedwait(() -> claude.is_reader_done, 2.0)
        _report_exit!(claude)
    end)
    claude
end

function _forward_claude_errors!(errors::IO)
    for line in eachline(errors)
        println(stderr, "claude: ", line)
    end
end

function _read_claude_events!(claude::ClaudeProcess)
    try
        for line in eachline(claude.output)
            isempty(strip(line)) && continue
            event = try
                JSON.parse(line; dicttype = Dict{String,Any})
            catch exception
                exception isa InterruptException && rethrow()
                @warn "claude wrote a line that is not JSON."
                continue
            end
            event isa Dict{String,Any} || continue
            if get(event, "type", nothing) == "system" && get(event, "subtype", nothing) == "init"
                capabilities = get(event, "capabilities", nothing)
                capabilities isa AbstractVector && (claude.capabilities = String[string(item) for item in capabilities])
            end
            _take_control_answer!(claude, event) || put!(claude.events, event)
        end
    catch exception
        claude.is_closed || exception isa Base.IOError || @warn "The reader of claude stopped." exception
    finally
        claude.is_reader_done = true
        _report_exit!(claude)
    end
end

# A `control_response` to a request that waits for it goes to that request.
# Answers whether the event went there.
function _take_control_answer!(claude::ClaudeProcess, event::Dict{String,Any})
    get(event, "type", nothing) == "control_response" || return false
    response = get(event, "response", nothing)
    request_id = response isa AbstractDict ? get(response, "request_id", nothing) : nothing
    request_id isa AbstractString || return false
    answer = lock(() -> pop!(claude.waiting_answers, request_id, nothing), claude.answer_lock)
    answer === nothing && return false
    put!(answer, Dict{String,Any}(response))
    true
end

# The event `process_exit`, once.
_report_exit!(claude::ClaudeProcess) =
    Threads.atomic_xchg!(claude.is_exit_reported, true) ||
        put!(claude.events, Dict{String,Any}("type" => "process_exit"))

"""
    send_user_message!(claude, content::Vector)

Send a user message: `content` holds its blocks, as `{"type": "text", "text": …}`.
"""
send_user_message!(claude::ClaudeProcess, content::Vector) =
    _write_claude_line!(claude, Dict{String,Any}("type" => "user", "message" => Dict{String,Any}(
        "role" => "user", "content" => content)))

"""
    interrupt_claude!(claude)

End the turn that runs. A `claude` that announced the capability
`interrupt_receipt_v1` gets the interrupt message on its standard input and
stays for the next message. Another one gets `SIGINT`, which ends the turn and
then the process, so it counts as ending. A process that is closed or ending
gets nothing.
"""
function interrupt_claude!(claude::ClaudeProcess)
    (claude.is_closed || claude.is_ending) && return nothing
    if "interrupt_receipt_v1" in claude.capabilities
        _send_control_request!(claude, Dict{String,Any}("subtype" => "interrupt"))
    elseif claude.process !== nothing && !process_exited(claude.process)
        claude.is_ending = true
        kill(claude.process, Base.SIGINT)
    end
    nothing
end

"""
    stop_claude_task!(claude, task_id) -> Union{Nothing,String}

Stop a background task or a subagent of `claude` with the control request
`stop_task`, and wait at most ten seconds for the answer of `claude`. Answers
`nothing` when `claude` stopped it, and else why it did not: the error that
`claude` answers, or that no answer came.
"""
function stop_claude_task!(claude::ClaudeProcess, task_id::AbstractString)
    (claude.is_closed || claude.is_ending) && return "Claude Code does not run."
    request_id = string(uuid4())
    answer = Channel{Dict{String,Any}}(1)
    lock(() -> claude.waiting_answers[request_id] = answer, claude.answer_lock)
    try
        _send_control_request!(claude, Dict{String,Any}("subtype" => "stop_task", "task_id" => String(task_id));
                               request_id)
        timedwait(() -> isready(answer) || claude.is_reader_done, 10.0)
        isready(answer) || return "Claude Code did not answer the stop of `$(task_id)`."
        response = take!(answer)
        get(response, "subtype", nothing) == "success" && return nothing
        message = get(response, "error", nothing)
        message isa AbstractString && !isempty(message) ? String(message) :
            "Claude Code did not stop `$(task_id)`."
    finally
        lock(() -> delete!(claude.waiting_answers, request_id), claude.answer_lock)
    end
end

# A control request on the standard input of `claude`, with the request id
# that its `control_response` names. A process whose input closed meanwhile gets
# nothing.
function _send_control_request!(claude::ClaudeProcess, request::Dict{String,Any};
                                request_id::String = string(uuid4()))
    try
        _write_claude_line!(claude, Dict{String,Any}("type" => "control_request",
                                                     "request_id" => request_id, "request" => request))
    catch exception
        exception isa Base.IOError || exception isa ErrorException || rethrow()
    end
    nothing
end

"""
    close_claude_process!(claude)

End the process: its input closes, which ends `claude` at the end of the turn.
A process that still runs after five seconds gets `SIGTERM` in its whole group,
and after two more seconds `SIGKILL`. The group gets `SIGTERM` at the end in
any case, so no child of `claude` lives on.
"""
function close_claude_process!(claude::ClaudeProcess)
    was_closed = lock(claude.write_lock) do
        was_closed = claude.is_closed
        claude.is_closed = true
        was_closed || try
            close(claude.input)
        catch exception
            exception isa Base.IOError || rethrow()
        end
        was_closed
    end
    was_closed && return nothing
    process = claude.process
    process === nothing && return nothing
    if timedwait(() -> process_exited(process), 5.0) !== :ok
        _signal_group!(claude, Base.SIGTERM)
        timedwait(() -> process_exited(process), 2.0) === :ok || _signal_group!(claude, Base.SIGKILL)
    end
    _signal_group!(claude, Base.SIGTERM)
    nothing
end

"""
    is_claude_running(claude) -> Bool

Whether the process can take a message: it is not closed, not ending after a
`SIGINT`, and still runs.
"""
is_claude_running(claude::ClaudeProcess) =
    !claude.is_closed && !claude.is_ending && !claude.is_exit_reported[] &&
    (claude.process === nothing || !process_exited(claude.process))

# The group is the process and every process that it started; its id is the id
# of the process from its start. A group with no process left answers the
# signal with `ESRCH`.
function _signal_group!(claude::ClaudeProcess, signal::Integer)
    if Sys.isunix()
        claude.process_id > 0 && ccall(:kill, Cint, (Cint, Cint), -claude.process_id, signal)
    else
        process = claude.process
        process === nothing || process_exited(process) || kill(process, signal)
    end
    nothing
end

function _write_claude_line!(claude::ClaudeProcess, message::Dict{String,Any})
    text = JSON.json(message)
    lock(claude.write_lock) do
        claude.is_closed && error("The claude process is closed.")
        write(claude.input, text, '\n')
        flush(claude.input)
    end
    nothing
end
