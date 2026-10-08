# The `claude` program in print mode, with stream-json on its standard input and
# output: one process for each session of the agent.

"""
    ClaudeProcess

One `claude -p` process: the stream that takes its messages, and the events
that it writes, one JSON object on each line. A task reads the events into
`events`; the last event is `{"type": "process_exit"}`.
`capabilities` holds the capabilities of its last `system/init`.
"""
mutable struct ClaudeProcess
    process::Union{Nothing,Base.Process}
    input::IO
    output::IO
    events::Channel{Dict{String,Any}}
    capabilities::Vector{String}
    write_lock::ReentrantLock
    is_closed::Bool
end

# The variables of the environment that tie a process to a session of Claude
# Code that runs it. A `claude` that the agent starts belongs to no such session,
# so it does not get them.
const PARENT_SESSION_VARIABLES = ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_AGENT_SDK_VERSION")

"""
    open_claude_process(streams::Tuple{IO,IO}) -> ClaudeProcess
    open_claude_process(command::Cmd) -> ClaudeProcess

Talk to `claude` on two streams, `(input, output)`, or start `command` in a
process group of its own. Each line of its standard error goes to the standard
error of the agent.
"""
function open_claude_process(streams::Tuple{IO,IO}; process::Union{Nothing,Base.Process} = nothing)
    input, output = streams
    claude = ClaudeProcess(process, input, output, Channel{Dict{String,Any}}(Inf), String[],
                           ReentrantLock(), false)
    errormonitor(@async _read_claude_events(claude))
    claude
end

function open_claude_process(command::Cmd)
    errors = Pipe()
    environment = filter(pair -> !(first(pair) in PARENT_SESSION_VARIABLES), ENV)
    command = Cmd(command; detach = true, env = Dict{String,String}(environment))
    process = open(pipeline(command; stderr = errors), "r+")
    close(errors.in)
    errormonitor(@async _forward_claude_errors(errors))
    open_claude_process((process.in, process.out); process)
end

function _forward_claude_errors(errors::IO)
    for line in eachline(errors)
        println(stderr, "claude: ", line)
    end
end

function _read_claude_events(claude::ClaudeProcess)
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
            put!(claude.events, event)
        end
    catch exception
        claude.is_closed || exception isa Base.IOError || @warn "The reader of claude stopped." exception
    finally
        put!(claude.events, Dict{String,Any}("type" => "process_exit"))
    end
end

"""
    send_user_message!(claude, content::Vector)

Send a user message: `content` holds its blocks, as `{"type": "text", "text": …}`.
"""
send_user_message!(claude::ClaudeProcess, content::Vector) =
    _write_claude_line!(claude, Dict{String,Any}("type" => "user", "message" => Dict{String,Any}(
        "role" => "user", "content" => content)))

"""
    interrupt_claude!(claude)

End the turn that runs. A `claude` whose `system/init` lists the capability
`interrupt_receipt_v1` gets the interrupt message on its standard input and
stays for the next message. Another one gets `SIGINT`, which ends the turn and
then the process.
"""
function interrupt_claude!(claude::ClaudeProcess)
    if "interrupt_receipt_v1" in claude.capabilities
        _write_claude_line!(claude, Dict{String,Any}("type" => "control_request",
            "request_id" => string(uuid4()), "request" => Dict{String,Any}("subtype" => "interrupt")))
    elseif claude.process !== nothing && !process_exited(claude.process)
        kill(claude.process, Base.SIGINT)
    end
    nothing
end

"""
    close_claude_process!(claude)

End the process: its input closes, which ends `claude` at the end of the turn.
A process that still runs after five seconds gets `SIGTERM` in its whole
group, and after two more seconds `SIGKILL`.
"""
function close_claude_process!(claude::ClaudeProcess)
    lock(claude.write_lock) do
        claude.is_closed && return nothing
        claude.is_closed = true
        try
            close(claude.input)
        catch exception
            exception isa Base.IOError || rethrow()
        end
    end
    process = claude.process
    process === nothing && return nothing
    if timedwait(() -> process_exited(process), 5.0) !== :ok
        _signal_group!(process, Base.SIGTERM)
        timedwait(() -> process_exited(process), 2.0) === :ok || _signal_group!(process, Base.SIGKILL)
    end
    nothing
end

is_claude_running(claude::ClaudeProcess) =
    !claude.is_closed && (claude.process === nothing || !process_exited(claude.process))

function _signal_group!(process::Base.Process, signal::Integer)
    if Sys.isunix()
        ccall(:kill, Cint, (Cint, Cint), -getpid(process), signal)
    else
        process_exited(process) || kill(process, signal)
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
