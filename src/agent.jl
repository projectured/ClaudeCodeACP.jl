# The agent: the handler of the requests of an editor, and its sessions, each
# with its own `claude` process.

"""
    AgentSettings(; claude_command, strict_mcp_config, start_claude, read_sign_in, run_sign_out)

- `claude_command`    — the program `claude` and its first arguments.
- `strict_mcp_config` — give `claude` only the MCP servers of the editor and the
  permission tool, with `--strict-mcp-config`, and not the MCP servers and the
  connectors of the configuration of the person.
- `start_claude(arguments, directory; capabilities)` — starts `claude` and
  answers its `ClaudeProcess`; a test gives a fake.
- `read_sign_in(claude_command)` — answers whether `claude` is signed in, or
  `nothing` when it can not tell.
- `run_sign_out(claude_command)` — signs `claude` out, and throws when it can
  not; a test gives a fake.
- `read_thinking_display(claude_command)` — answers whether `claude` takes the
  flag `--thinking-display`.
"""
Base.@kwdef struct AgentSettings
    claude_command::Vector{String} = ["claude"]
    strict_mcp_config::Bool = false
    start_claude::Function = (arguments, directory; capabilities = String[]) ->
        open_claude_process(Cmd(Cmd(arguments); dir = directory); capabilities)
    read_sign_in::Function = read_claude_sign_in
    run_sign_out::Function = run_claude_sign_out
    read_thinking_display::Function = read_claude_thinking_display
end

"""
    ClaudeSession

One session of the agent: its id, which is also the session id of `claude`, its
folder, the MCP servers of the editor, the text that the editor adds to the
system prompt, the secret of its permission tool and the private folder of its
configuration, its options, its `claude` process, the translation of its events,
and the state of its turns. While a prompt runs, `sent_messages` counts the user
messages that went to `claude` for it, `taken_messages` the ones that `claude`
echoed when a turn took them, `is_steerable` says that a message can still go
into it, and `prompt_end` takes its stop reason or its error from the reader of
the events. `reported_process` is the process whose id went to the editor.
`send_lock` keeps the messages of the translation in their order; a task that
holds it may take `lock`, and never the other way round.
"""
mutable struct ClaudeSession
    id::String
    directory::String
    mcp_servers::Vector{Any}
    system_prompt::String
    secret::String
    config_folder::String
    options::Dict{String,String}
    chosen_options::Set{String}
    process::Union{Nothing,ClaudeProcess}
    capabilities::Vector{String}
    has_history::Bool
    needs_restart::Bool
    title::Union{Nothing,String}
    commands::Vector{String}
    always_allowed::Set{String}
    translation::SessionTranslation
    is_prompting::Bool
    is_cancelled::Bool
    is_closed::Bool
    sent_messages::Int
    taken_messages::Int
    is_steerable::Bool
    prompt_end::Union{Nothing,Channel{Any}}
    reported_process::Union{Nothing,ClaudeProcess}
    waiting_permissions::Vector{ACP.OutgoingRequest}
    lock::ReentrantLock
    send_lock::ReentrantLock
end

"""
    ClaudeCodeAgent(settings = AgentSettings())

The ACP agent that runs Claude Code. Serve an editor with
`open_connection(ClaudeCodeAgent(), stdin, stdout)`, or with [`serve_agent`](@ref).
"""
mutable struct ClaudeCodeAgent <: ACP.AgentHandler
    settings::AgentSettings
    sessions::Dict{String,ClaudeSession}
    permission::Union{Nothing,PermissionServer}
    connection::Union{Nothing,ACP.Connection}
    has_thinking_display::Union{Nothing,Bool}
    has_question_forms::Bool
    features::ClientFeatures
    lock::ReentrantLock
end

ClaudeCodeAgent(settings::AgentSettings = AgentSettings()) =
    ClaudeCodeAgent(settings, Dict{String,ClaudeSession}(), nothing, nothing, nothing, false, ClientFeatures(),
                    ReentrantLock())

# --- The options of a session ------------------------------------------------

# Each option: its id, its name, its category, its flag, and its values with
# their names. The value "default" gives `claude` no flag, so the configuration
# of the person decides.
const SESSION_OPTIONS = [
    (id = "mode", name = "Mode", category = "mode", flag = "--permission-mode",
     values = ["default" => "Ask before edits", "acceptEdits" => "Accept edits", "plan" => "Plan",
               "auto" => "Auto", "bypassPermissions" => "Bypass permissions"]),
    (id = "model", name = "Model", category = "model", flag = "--model",
     values = ["default" => "Default", "opus" => "Opus", "sonnet" => "Sonnet", "haiku" => "Haiku",
               "fable" => "Fable"]),
    (id = "effort", name = "Effort", category = "thought_level", flag = "--effort",
     values = ["default" => "Default", "low" => "Low", "medium" => "Medium", "high" => "High",
               "xhigh" => "Extra high", "max" => "Max"])]

# The value of `--permission-mode` for the mode "default" that a person chose.
const DEFAULT_MODE_FLAG_VALUE = "manual"

"""
    make_config_options(session) -> Vector{ACP.SessionConfigOption}

The options of a session, with their current values.
"""
make_config_options(session::ClaudeSession) = ACP.SessionConfigOption[
    ACP.SessionConfigOptionSelect(
        id = option.id, name = option.name, category = option.category,
        current_value = get(session.options, option.id, "default"),
        options = ACP.SessionConfigSelectOption[ACP.SessionConfigSelectOption(value = value, name = name)
                                                for (value, name) in option.values])
    for option in SESSION_OPTIONS]

# --- The command line of `claude` --------------------------------------------

"""
    make_claude_arguments(agent, session, mcp_config_path) -> Vector{String}

The command line of the `claude` of a session: print mode with stream-json in
and out, the stream of partial messages, the text of the thinking with the
setting `showThinkingSummaries` and, when `claude` takes it, the flag
`--thinking-display summarized`, the permission tool, the session id or the
session to resume, the options that the person chose, the file of the addition
to the system prompt when the editor gave one, and the file of the MCP
configuration, which holds the secrets and so is not on the command line.
"""
function make_claude_arguments(agent::ClaudeCodeAgent, session::ClaudeSession, mcp_config_path::String;
                               system_prompt_path::Union{Nothing,String} = nothing)
    arguments = String[agent.settings.claude_command..., "-p",
                       "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--include-partial-messages", "--replay-user-messages",
                       "--settings", JSON.json(Dict("showThinkingSummaries" => true)),
                       "--permission-prompt-tool", PERMISSION_TOOL_NAME]
    _has_thinking_display!(agent) && append!(arguments, ["--thinking-display", "summarized"])
    # An editor that can not show a form gets no question from the tool, and
    # Claude asks in its text.
    agent.has_question_forms || push!(arguments, "--disallowedTools=AskUserQuestion")
    append!(arguments, session.has_history ? ["--resume", session.id] : ["--session-id", session.id])
    for option in SESSION_OPTIONS
        option.id in session.chosen_options || continue
        value = session.options[option.id]
        value == "default" && option.id != "mode" && continue
        append!(arguments, [option.flag, option.id == "mode" && value == "default" ? DEFAULT_MODE_FLAG_VALUE : value])
    end
    agent.settings.strict_mcp_config && push!(arguments, "--strict-mcp-config")
    system_prompt_path === nothing || append!(arguments, ["--append-system-prompt-file", system_prompt_path])
    append!(arguments, ["--mcp-config", mcp_config_path])
    arguments
end

"""
    make_mcp_config(agent, session) -> Dict

The MCP configuration of the `claude` of a session: the MCP servers of the
editor, and the permission server with the secret of the session.
"""
function make_mcp_config(agent::ClaudeCodeAgent, session::ClaudeSession)
    servers = Dict{String,Any}()
    for server in session.mcp_servers
        config = _make_mcp_server_config(server)
        config === nothing || (servers[first(config)] = last(config))
    end
    servers[PERMISSION_SERVER_NAME] = make_permission_mcp_server(_get_or_start_permission_server!(agent),
                                                                 session.secret)
    Dict{String,Any}("mcpServers" => servers)
end

# The MCP configuration in the private folder of the session, which only this
# user can read. Answers its path.
function _write_mcp_config!(agent::ClaudeCodeAgent, session::ClaudeSession)
    path = joinpath(session.config_folder, "mcp.json")
    open(path, "w") do file
        chmod(path, 0o600)
        JSON.json(file, make_mcp_config(agent, session))
    end
    path
end

# The addition to the system prompt in the private folder of the session, or
# `nothing` when the editor gave none. Answers its path.
function _write_system_prompt!(session::ClaudeSession)
    isempty(session.system_prompt) && return nothing
    path = joinpath(session.config_folder, "system-prompt.md")
    write(path, session.system_prompt)
    path
end

"""
    read_system_prompt_addition(meta) -> String

The text that an editor adds to the system prompt of a session, from the `_meta`
of `session/new` or `session/resume`: `claudeCode.options.systemPrompt.append`,
where the Claude agents of ACP read it. Empty when the `_meta` has none.
"""
function read_system_prompt_addition(meta)
    for key in ("claudeCode", "options", "systemPrompt")
        meta isa AbstractDict || return ""
        meta = get(meta, key, nothing)
    end
    meta isa AbstractDict || return ""
    addition = get(meta, "append", nothing)
    addition isa AbstractString ? String(addition) : ""
end

# The entry of an MCP server of the editor in the configuration of `claude`, as
# `name => config`, or `nothing` for a kind that `claude` can not reach.
function _make_mcp_server_config(server)
    if server isa ACP.McpServerHttp || server isa ACP.McpServerSse
        return server.name => Dict{String,Any}(
            "type" => server isa ACP.McpServerHttp ? "http" : "sse", "url" => server.url,
            "headers" => Dict{String,Any}(header.name => header.value for header in server.headers))
    elseif server isa ACP.McpServerStdio
        return server.name => Dict{String,Any}(
            "type" => "stdio", "command" => server.command, "args" => server.args,
            "env" => Dict{String,Any}(variable.name => variable.value for variable in server.env))
    end
    @warn "An MCP server of a kind that claude can not reach is left out." kind = nameof(typeof(server))
    nothing
end

function _get_or_start_permission_server!(agent::ClaudeCodeAgent)
    lock(agent.lock) do
        agent.permission === nothing &&
            (agent.permission = start_permission_server!(secret -> _find_session_by_secret(agent, secret),
                (session, tool_name, input, tool_use_id) ->
                    decide_permission!(agent, session, tool_name, input, tool_use_id)))
        agent.permission
    end
end

function _find_session_by_secret(agent::ClaudeCodeAgent, secret::AbstractString)
    sessions = lock(() -> collect(values(agent.sessions)), agent.lock)
    found = nothing
    for session in sessions
        is_same_secret(session.secret, secret) && (found = session)
    end
    found
end

# --- The sign-in -------------------------------------------------------------

"""
    read_claude_sign_in(claude_command) -> Union{Bool,Nothing}

Whether `claude` is signed in, from `claude auth status --json`. Reads only its
field `loggedIn`; the rest of the status, such as the email of the account, is
neither kept nor logged. Answers `nothing` when the status does not come.
"""
function read_claude_sign_in(claude_command::Vector{String})
    output = IOBuffer()
    command = Cmd(Cmd([claude_command..., "auth", "status", "--json"]); env = make_claude_environment(),
                  ignorestatus = true)
    process = try
        run(pipeline(command; stdout = output, stderr = devnull); wait = false)
    catch exception
        exception isa Base.IOError || rethrow()
        return nothing
    end
    if timedwait(() -> process_exited(process), 20.0) !== :ok
        kill(process)
        return nothing
    end
    # The wait also ends the copy of the output into the buffer.
    wait(process)
    status = try
        JSON.parse(String(take!(output)))
    catch exception
        exception isa InterruptException && rethrow()
        nothing
    end
    signed_in = status isa AbstractDict ? get(status, "loggedIn", nothing) : nothing
    signed_in isa Bool ? signed_in : nothing
end

"""
    make_login_command(settings = AgentSettings()) -> Cmd

The command of the sign-in of the agent: `claude auth login`, with the `claude`
command of `settings`, in the environment that the agent gives `claude`. A
person answers it in a terminal, and it ends with the status 0 when the sign-in
worked. `claude-code-acp --login` runs it, and an editor that runs the agent in
its own process runs it for the method `claude-login`.
"""
make_login_command(settings::AgentSettings = AgentSettings()) =
    Cmd(Cmd([settings.claude_command..., "auth", "login"]); env = make_claude_environment())

"""
    run_claude_sign_out(claude_command) -> Nothing

Sign `claude` out with `claude auth logout`. Throws a `ProtocolException` when
the command does not start, does not end in 20 seconds, or fails. The message
names only the exit status, not what `claude` wrote.
"""
function run_claude_sign_out(claude_command::Vector{String})
    command = Cmd(Cmd([claude_command..., "auth", "logout"]); env = make_claude_environment(),
                  ignorestatus = true)
    process = try
        run(pipeline(command; stdout = devnull, stderr = devnull); wait = false)
    catch exception
        exception isa Base.IOError || rethrow()
        throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "The program `$(first(claude_command))` can not start."))
    end
    if timedwait(() -> process_exited(process), 20.0) !== :ok
        kill(process)
        throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "`claude auth logout` did not end in 20 seconds."))
    end
    process.exitcode == 0 ||
        throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "`claude auth logout` failed with the status $(process.exitcode)."))
    nothing
end

"""
    read_claude_thinking_display(claude_command) -> Bool

Whether `claude` takes the flag `--thinking-display`, which a recent model
needs to stream the summary of its thinking in print mode, and which the help
of `claude` does not list. A `claude` that knows the flag refuses a wrong value
of it and names the flag; one that does not know it prints its version.
"""
function read_claude_thinking_display(claude_command::Vector{String})
    errors = IOBuffer()
    command = Cmd(Cmd([claude_command..., "--thinking-display", "no-such-display", "--version"]);
                  env = make_claude_environment(), ignorestatus = true)
    process = try
        run(pipeline(command; stdout = devnull, stderr = errors); wait = false)
    catch exception
        exception isa Base.IOError || rethrow()
        return false
    end
    if timedwait(() -> process_exited(process), 20.0) !== :ok
        kill(process)
        return false
    end
    wait(process)
    process.exitcode != 0 && occursin("--thinking-display", String(take!(errors)))
end

# Whether the command line of `claude` gets `--thinking-display`, read once.
function _has_thinking_display!(agent::ClaudeCodeAgent)
    known = lock(() -> agent.has_thinking_display, agent.lock)
    known === nothing || return known
    found = agent.settings.read_thinking_display(agent.settings.claude_command)
    lock(() -> agent.has_thinking_display = found, agent.lock)
    found
end

function _require_sign_in(agent::ClaudeCodeAgent)
    agent.settings.read_sign_in(agent.settings.claude_command) === false &&
        throw(ACP.ProtocolException(ACP.AUTHENTICATION_REQUIRED,
                                    "Claude Code is not signed in. Run `claude auth login` in a terminal."))
    nothing
end

# --- The requests of the editor ----------------------------------------------

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.InitializeRequest, context)
    agent.connection = context.connection
    agent.has_question_forms = _has_question_forms(request)
    agent.features = _read_client_features(request)
    ACP.InitializeResponse(
        protocol_version = ACP.PROTOCOL_VERSION,
        # The extension method `_session/steering` takes a prompt into the turn
        # that runs, as `claude-agent-acp` names it. The extension notification
        # `_session/background_task` and the request
        # `_session/stop_background_task` show and stop the background tasks.
        meta = Dict{String,Any}("steering" => Dict{String,Any}("supported" => true),
                                "backgroundTasks" => Dict{String,Any}("supported" => true)),
        agent_capabilities = ACP.AgentCapabilities(
            load_session = false,
            prompt_capabilities = ACP.PromptCapabilities(image = true, audio = false, embedded_context = true),
            mcp_capabilities = ACP.McpCapabilities(http = true, sse = true),
            session_capabilities = ACP.SessionCapabilities(close = ACP.SessionCloseCapabilities(),
                                                           resume = ACP.SessionResumeCapabilities()),
            auth = ACP.AgentAuthCapabilities(logout = ACP.LogoutCapabilities())),
        agent_info = ACP.Implementation(name = "claude-code-acp", title = "Claude Code",
                                        version = string(pkgversion(@__MODULE__))),
        auth_methods = _has_terminal_auth(request) ? ACP.AuthMethod[ACP.AuthMethodTerminal(
            id = "claude-login", name = "Sign in to Claude Code",
            description = "Run `claude auth login` in a terminal.", args = ["--login"])] : ACP.AuthMethod[])
end

# Whether the editor shows a form for a question: it says so with
# `clientCapabilities.elicitation.form`.
function _has_question_forms(request::ACP.InitializeRequest)
    capabilities = request.client_capabilities
    elicitation = capabilities === nothing ? nothing : capabilities.elicitation
    elicitation !== nothing && elicitation.form !== nothing
end

# The updates beyond version 1 of ACP that the editor takes:
# `clientCapabilities.subagents`, `.plan`, `.session.notices`,
# `.session.compaction`, and an object at `._meta.backgroundTasks`.
function _read_client_features(request::ACP.InitializeRequest)
    capabilities = request.client_capabilities
    capabilities === nothing && return ClientFeatures()
    session = capabilities.session
    meta = capabilities.meta
    ClientFeatures(subagents = capabilities.subagents !== nothing, plans = capabilities.plan !== nothing,
                   notices = session !== nothing && session.notices !== nothing,
                   compaction = session !== nothing && session.compaction !== nothing,
                   background_tasks = meta !== nothing && get(meta, "backgroundTasks", nothing) isa AbstractDict)
end

# Whether the editor runs a sign-in in a terminal. It says so with
# `clientCapabilities.auth.terminal`, and only then can the agent name one.
function _has_terminal_auth(request::ACP.InitializeRequest)
    capabilities = request.client_capabilities
    auth = capabilities === nothing ? nothing : capabilities.auth
    auth !== nothing && auth.terminal === true
end

# A `claude` that runs keeps its sign-in until it ends. So a sign-out also
# starts the `claude` of each session again, and that start asks for a sign-in.
function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.LogoutRequest, context)
    agent.settings.run_sign_out(agent.settings.claude_command)
    for session in lock(() -> collect(values(agent.sessions)), agent.lock)
        lock(() -> session.needs_restart = true, session.lock)
    end
    ACP.LogoutResponse()
end

ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.AuthenticateRequest, context) = ACP.AuthenticateResponse()

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.NewSessionRequest, context)
    agent.connection = context.connection
    _require_sign_in(agent)
    session = _open_session!(agent, string(uuid4()), request.cwd, request.mcp_servers; has_history = false,
                             system_prompt = read_system_prompt_addition(request.meta))
    ACP.NewSessionResponse(session_id = session.id, config_options = make_config_options(session))
end

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.ResumeSessionRequest, context)
    agent.connection = context.connection
    _require_sign_in(agent)
    session = _open_session!(agent, request.session_id, request.cwd, something(request.mcp_servers, Any[]);
                             has_history = true, system_prompt = read_system_prompt_addition(request.meta))
    ACP.ResumeSessionResponse(config_options = make_config_options(session))
end

function _open_session!(agent::ClaudeCodeAgent, id::String, directory::String, mcp_servers;
                        has_history::Bool, system_prompt::String = "")
    isabspath(directory) && isdir(directory) ||
        throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The folder `$(directory)` is no absolute path of a folder."))
    session = ClaudeSession(id, directory, collect(Any, mcp_servers), system_prompt, make_session_secret(), mktempdir(),
                            Dict(option.id => "default" for option in SESSION_OPTIONS), Set{String}(),
                            nothing, String[], has_history, false, nothing, String[], Set{String}(),
                            SessionTranslation(id; features = agent.features), false, false, false, 0, 0, false,
                            nothing, nothing, ACP.OutgoingRequest[], ReentrantLock(), ReentrantLock())
    is_open = lock(agent.lock) do
        haskey(agent.sessions, id) || (agent.sessions[id] = session; return false)
        true
    end
    if is_open
        rm(session.config_folder; recursive = true, force = true)
        throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The session `$(id)` is open."))
    end
    try
        _start_claude!(agent, session)
    catch
        lock(() -> delete!(agent.sessions, id), agent.lock)
        rm(session.config_folder; recursive = true, force = true)
        rethrow()
    end
    session
end

# Start the `claude` of a session, in place of the one before, and the reader of
# its events. The subagents and the background tasks that still run in the one
# before end with it. A session that closed meanwhile keeps no process: the new
# one ends at once. Answers whether the session has the new process.
function _start_claude!(agent::ClaudeCodeAgent, session::ClaudeSession)
    previous = session.process
    previous === nothing || isempty(previous.capabilities) || (session.capabilities = copy(previous.capabilities))
    arguments = make_claude_arguments(agent, session, _write_mcp_config!(agent, session);
                                      system_prompt_path = _write_system_prompt!(session))
    process = try
        agent.settings.start_claude(arguments, session.directory; capabilities = session.capabilities)
    catch exception
        exception isa Base.IOError || rethrow()
        # The message of the exception quotes the command line, so the answer
        # names only the error of the system.
        reason = exception.code < 0 ? Libc.strerror(-exception.code) : "error $(exception.code)"
        throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "The program `$(first(agent.settings.claude_command))` " *
                                    "can not start: $(reason). Install Claude Code, or give its path."))
    end
    is_closed = lock(session.send_lock) do
        ended = Pair{String,Any}[]
        is_closed = lock(session.lock) do
            if !session.is_closed
                previous === nothing || (ended = end_running_tasks!(session.translation, "stopped"))
                session.process = process
                session.needs_restart = false
            end
            session.is_closed
        end
        _send_messages_quietly!(agent, ended)
        is_closed
    end
    if is_closed
        close_claude_process!(process)
    else
        errormonitor(@async _follow_claude!(agent, session, process))
    end
    !is_closed
end

function _get_session(agent::ClaudeCodeAgent, id::AbstractString)
    session = lock(() -> get(agent.sessions, id, nothing), agent.lock)
    session === nothing && throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "No session `$(id)` is open."))
    session
end

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.SetSessionConfigOptionRequest, context)
    session = _get_session(agent, request.session_id)
    request isa ACP.SetSessionConfigOptionRequestValueId ||
        throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The options of this agent take a value id."))
    index = findfirst(option -> option.id == request.config_id, SESSION_OPTIONS)
    index === nothing && throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "No option `$(request.config_id)`."))
    option = SESSION_OPTIONS[index]
    any(pair -> first(pair) == request.value, option.values) ||
        throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The option `$(option.id)` has no value `$(request.value)`."))
    # The next prompt starts `claude` again with `--resume` and the new flags.
    lock(session.lock) do
        session.options[option.id] = request.value
        push!(session.chosen_options, option.id)
        session.needs_restart = true
    end
    ACP.SetSessionConfigOptionResponse(config_options = make_config_options(session))
end

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.CloseSessionRequest, context)
    session = lock(() -> pop!(agent.sessions, request.session_id, nothing), agent.lock)
    session === nothing || _close_session!(session)
    ACP.CloseSessionResponse()
end

# A close works as a cancel of the prompt that runs, and then ends `claude`.
function _close_session!(session::ClaudeSession)
    process, requests = lock(session.lock) do
        session.is_closed = true
        session.is_prompting && (session.is_cancelled = true)
        session.process, copy(session.waiting_permissions)
    end
    foreach(_cancel_quietly!, requests)
    if process !== nothing
        interrupt_claude!(process)
        close_claude_process!(process)
    end
    rm(session.config_folder; recursive = true, force = true)
    nothing
end

function _cancel_quietly!(request::ACP.OutgoingRequest)
    try
        ACP.cancel_request!(request)
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
    end
end

"""
    close_agent!(agent)

End each session of the agent and its `claude`, all at once, and stop the
permission server.
"""
function close_agent!(agent::ClaudeCodeAgent)
    sessions = lock(agent.lock) do
        sessions = collect(values(agent.sessions))
        empty!(agent.sessions)
        sessions
    end
    @sync for session in sessions
        @async _close_session!(session)
    end
    permission = lock(() -> (permission = agent.permission; agent.permission = nothing; permission), agent.lock)
    permission === nothing || stop_permission_server!(permission)
    nothing
end

# --- A prompt ----------------------------------------------------------------

# The error of a `result` that ends a prompt: `claude` is ready for the next
# message after it.
struct FailedTurn
    exception::ACP.ProtocolException
end

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.PromptRequest, context)
    session = _get_session(agent, request.session_id)
    lock(session.lock) do
        session.is_closed && throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The session is closed."))
        session.is_prompting && throw(ACP.ProtocolException(ACP.INVALID_REQUEST, "A prompt runs in this session."))
        session.is_prompting = true
        session.is_cancelled = false
    end
    connection = context.connection
    is_sent = false
    is_failed_turn = false
    try
        content = _make_claude_content(request.prompt)
        process = session.process
        if process === nothing || session.needs_restart || !is_claude_running(process)
            if process !== nothing
                # The work of a `claude` that ended by itself failed; the work
                # of one that the agent ends stops.
                status = process.is_closed || process.is_ending || is_claude_running(process) ? "stopped" : "failed"
                _end_claude_work!(agent, session, process, status)
                close_claude_process!(process)
            end
            _require_sign_in(agent)
            _start_claude!(agent, session)
        end
        # A cancel or a close that came during the start ends the prompt here,
        # before `claude` gets the message.
        lock(() -> session.is_cancelled, session.lock) && return ACP.PromptResponse(stop_reason = "cancelled")
        # Only the first prompt of a session names it. A resumed session has its
        # title in the editor already, so a later prompt does not rename it.
        if session.title === nothing && !session.has_history
            session.title = make_title(request.prompt)
            session.title === nothing ||
                ACP.send_session_update!(connection, session.id, ACP.SessionInfoUpdate(title = session.title))
        end
        agent.features.background_tasks && _send_process_id!(session, connection)
        # The reader of the events gives the prompt its end. A `claude` that
        # ended before the message went to it gives no events any more.
        prompt_end = Channel{Any}(1)
        lock(session.lock) do
            is_claude_running(session.process) ||
                throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "Claude Code ended before the end of the turn."))
            send_user_message!(session.process, content)
            session.sent_messages = 1
            session.taken_messages = 0
            session.is_steerable = true
            session.prompt_end = prompt_end
        end
        is_sent = true
        session.has_history = true
        outcome = take!(prompt_end)
        if outcome isa FailedTurn
            is_failed_turn = true
            throw(outcome.exception)
        end
        outcome isa Exception && throw(outcome)
        ACP.PromptResponse(stop_reason = outcome)
    catch
        # A failure after the message went to `claude`, but for the error of a
        # `result`, leaves `claude` in a state that the agent does not know, so
        # the next prompt starts it again.
        is_sent && !is_failed_turn && (session.needs_restart = true)
        rethrow()
    finally
        lock(session.lock) do
            session.is_prompting = false
            session.prompt_end = nothing
        end
    end
end

# The process id of the `claude` of the session, as `_meta.processId` of a
# `session_info_update`, once for each process. A prompt sends it, so the
# editor knows the session already. A `claude` on two streams, as in a test, has
# no process id.
function _send_process_id!(session::ClaudeSession, connection::ACP.Connection)
    process = session.process
    (process === nothing || process === session.reported_process || process.process_id <= 0) && return nothing
    session.reported_process = process
    ACP.send_session_update!(connection, session.id, ACP.SessionInfoUpdate(
        meta = Dict{String,Any}("processId" => Int(process.process_id))))
    nothing
end

# The reader of the events of the `claude` of a session, in their order, for as
# long as the process runs. While a prompt runs, each event goes to it, and the
# event that ends its turn gives the prompt its stop reason or its error.
# Between two prompts, each event goes to the editor at once, so a turn that
# `claude` starts by itself, when a background task ends, reaches the editor
# when it runs; an event that fails then leaves the reader for the next one. The
# end of the process ends the work that still runs in it. The events of a
# process that the session no longer has go nowhere.
function _follow_claude!(agent::ClaudeCodeAgent, session::ClaudeSession, process::ClaudeProcess)
    while true
        event = take!(process.events)
        is_exit = get(event, "type", nothing) == "process_exit"
        is_current, prompt_end = lock(() -> (session.process === process, session.prompt_end), session.lock)
        if is_current
            is_exit && _end_claude_work!(agent, session, process,
                                         process.is_closed || process.is_ending ? "stopped" : "failed")
            outcome = try
                _follow_event!(agent, session, process, event, prompt_end !== nothing)
            catch exception
                prompt_end === nothing && !(exception isa ACP.ProtocolException || exception isa Base.IOError) &&
                    @warn "An event of claude between two prompts failed." exception
                prompt_end === nothing ? nothing : exception
            end
            if outcome !== nothing
                lock(session.lock) do
                    session.prompt_end = nothing
                    session.is_steerable = false
                end
                put!(prompt_end, outcome)
            end
        end
        is_exit && return nothing
    end
end

# One event of `claude`, sent to the editor, while a prompt runs or between two
# prompts. Answers the end of the prompt when the event ends it: its stop
# reason, or the `FailedTurn` of a `result` that failed; and `nothing` else.
# Throws the error of a process that ended in a prompt. A `result` ends the
# prompt when the prompt is cancelled or `claude` took each of its messages;
# another one ends a turn that `claude` started by itself, and sends only the
# usage, as a `result` between two prompts does.
function _follow_event!(agent::ClaudeCodeAgent, session::ClaudeSession, process::ClaudeProcess,
                        event::Dict{String,Any}, is_prompting::Bool)
    connection = agent.connection
    (is_prompting || connection !== nothing) || return nothing
    type = get(event, "type", nothing)
    if type == "process_exit"
        is_prompting || return nothing
        session.needs_restart = true
        lock(() -> session.is_cancelled, session.lock) && return "cancelled"
        throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "Claude Code ended before the end of the turn."))
    elseif type == "system" && get(event, "subtype", nothing) == "init"
        _read_init!(session, event, connection)
    elseif type == "user" && get(event, "isReplay", false) === true
        # Claude Code echoes each user message when a turn takes it.
        is_prompting && lock(() -> session.taken_messages += 1, session.lock)
    elseif type == "result"
        _send_usage!(session, event, connection)
        lock(() -> empty!(session.translation.state.tool_calls), session.lock)
        is_prompting || return nothing
        is_ending = lock(() -> session.is_cancelled || session.taken_messages >= session.sent_messages, session.lock)
        is_ending || return nothing
        return try
            _read_stop_reason(session, event)
        catch exception
            exception isa ACP.ProtocolException || rethrow()
            FailedTurn(exception)
        end
    else
        _send_event_updates!(session, process, event, connection)
    end
    nothing
end

# The subagents and the background tasks that still run in a `claude` that ends
# end with it, with the status `status` of a background task: `stopped` when the
# agent ends it, and `failed` when it ended by itself. A closed session gets
# nothing.
function _end_claude_work!(agent::ClaudeCodeAgent, session::ClaudeSession, process::ClaudeProcess, status::String)
    lock(session.send_lock) do
        messages = lock(session.lock) do
            session.process === process && !session.is_closed ?
                end_running_tasks!(session.translation, status) : Pair{String,Any}[]
        end
        _send_messages_quietly!(agent, messages)
    end
end

# The updates of one event of `process` for the session and its subagents, and
# the notifications of its background tasks. An event of a process that the
# session no longer has gives none, so no work of it starts after its end. The
# send lock keeps the messages in the order of their translation, also against
# the end of the work at a start of `claude`.
function _send_event_updates!(session::ClaudeSession, process::ClaudeProcess, event::Dict{String,Any},
                              connection::ACP.Connection)
    lock(session.send_lock) do
        messages = lock(session.lock) do
            session.process === process ? translate_session_event!(session.translation, event) : Pair{String,Any}[]
        end
        _send_messages!(connection, messages)
    end
end

# The messages of the translation, as `session_id => message`, to the editor.
function _send_messages!(connection::ACP.Connection, messages::Vector{Pair{String,Any}})
    for (session_id, message) in messages
        if message isa BackgroundTaskNotification
            ACP.send_notification!(connection, "_session/background_task", message.params)
        else
            ACP.send_session_update!(connection, session_id, message)
        end
    end
end

# The messages of the translation to the editor of the agent, when it has one
# that can take them.
function _send_messages_quietly!(agent::ClaudeCodeAgent, messages::Vector{Pair{String,Any}})
    connection = agent.connection
    (connection === nothing || isempty(messages)) && return nothing
    try
        _send_messages!(connection, messages)
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
    end
    nothing
end

# The commands and the mode of `system/init`, sent when they change.
function _read_init!(session::ClaudeSession, event::Dict{String,Any}, connection::ACP.Connection)
    commands = get(event, "slash_commands", nothing)
    if commands isa AbstractVector
        names = String[string(command) for command in commands]
        if names != session.commands
            session.commands = names
            ACP.send_session_update!(connection, session.id, ACP.AvailableCommandsUpdate(
                available_commands = ACP.AvailableCommand[ACP.AvailableCommand(name = name, description = "")
                                                          for name in names]))
        end
    end
    mode = get(event, "permissionMode", nothing)
    if mode isa AbstractString && !("mode" in session.chosen_options)
        mode = mode == DEFAULT_MODE_FLAG_VALUE ? "default" : String(mode)
        values = first(option for option in SESSION_OPTIONS if option.id == "mode").values
        if mode != session.options["mode"] && any(pair -> first(pair) == mode, values)
            session.options["mode"] = mode
            ACP.send_session_update!(connection, session.id,
                                     ACP.ConfigOptionUpdate(config_options = make_config_options(session)))
        end
    end
end

# How much of its context the session uses: the context of the last request,
# out of the context window of the model, and the cost that `claude` estimates
# for the whole conversation, also across a `--resume`.
function _send_usage!(session::ClaudeSession, result::Dict{String,Any}, connection::ACP.Connection)
    size = 0
    model_usage = get(result, "modelUsage", nothing)
    if model_usage isa AbstractDict
        for usage in values(model_usage)
            usage isa AbstractDict && (size = max(size, _read_count(get(usage, "contextWindow", 0))))
        end
    end
    size == 0 && return nothing
    cost = get(result, "total_cost_usd", nothing)
    ACP.send_session_update!(connection, session.id, ACP.UsageUpdate(
        used = session.translation.state.context_used, size = size,
        cost = cost isa Real ? ACP.Cost(amount = Float64(cost), currency = "USD") : nothing))
    nothing
end

# The stop reason of a `result`, or an error answer for a turn that failed, with
# the message of `claude`, such as a sign-in that is missing.
function _read_stop_reason(session::ClaudeSession, result::Dict{String,Any})
    lock(() -> session.is_cancelled, session.lock) && return "cancelled"
    subtype = get(result, "subtype", "")
    terminal = get(result, "terminal_reason", nothing)
    terminal in ("aborted_streaming", "aborted_tools", "interrupted") && return "cancelled"
    subtype == "error_max_turns" && return "max_turn_requests"
    if subtype == "success" && get(result, "is_error", false) !== true
        stop = get(result, "stop_reason", nothing)
        stop == "max_tokens" && return "max_tokens"
        stop == "refusal" && return "refusal"
        return "end_turn"
    end
    message = get(result, "result", nothing)
    throw(ACP.ProtocolException(ACP.INTERNAL_ERROR,
                                message isa AbstractString && !isempty(message) ? String(message) :
                                "Claude Code ended the turn with the error `$(subtype)`."))
end

"""
    make_title(prompt) -> Union{String,Nothing}

The title of a session from a prompt: the first line of its text, with at most
80 characters.
"""
function make_title(prompt::AbstractVector)
    for block in prompt
        block isa ACP.TextContent || continue
        for line in split(block.text, '\n')
            text = join(split(line), ' ')
            isempty(text) && continue
            return length(text) <= 80 ? text : first(text, 79) * "…"
        end
    end
    nothing
end

# The blocks of a prompt as the content of a user message of `claude`. A link
# to a file becomes a mention of its path, an embedded text becomes text with its
# address, and a picture becomes an image with its bytes in base64.
function _make_claude_content(prompt::AbstractVector)
    content = Dict{String,Any}[]
    for block in prompt
        if block isa ACP.TextContent
            push!(content, Dict{String,Any}("type" => "text", "text" => block.text))
        elseif block isa ACP.ResourceLink
            path = _find_file_path(block.uri)
            push!(content, Dict{String,Any}("type" => "text", "text" => path === nothing ? block.uri : "@" * path))
        elseif block isa ACP.ImageContent
            block.mime_type in _IMAGE_TYPES && !isempty(block.data) ||
                throw(ACP.ProtocolException(ACP.INVALID_PARAMS,
                    "This agent takes a picture in base64, of the type " * join(_IMAGE_TYPES, ", ", " or ") * "."))
            push!(content, Dict{String,Any}("type" => "image", "source" => Dict{String,Any}(
                "type" => "base64", "media_type" => block.mime_type, "data" => block.data)))
        elseif block isa ACP.EmbeddedResource && block.resource isa ACP.TextResourceContents
            resource = block.resource
            push!(content, Dict{String,Any}("type" => "text", "text" =>
                "<context ref=\"$(resource.uri)\">\n$(resource.text)\n</context>"))
        else
            throw(ACP.ProtocolException(ACP.INVALID_PARAMS,
                                        "This agent takes text, pictures, links and embedded text, not a $(nameof(typeof(block)))."))
        end
    end
    content
end

# The types of a picture that Claude reads.
const _IMAGE_TYPES = ("image/png", "image/jpeg", "image/gif", "image/webp")

# The path of a `file:` URI, decoded, or `nothing` for another URI.
function _find_file_path(uri::AbstractString)
    for prefix in ("file://localhost/", "file:///")
        startswith(uri, prefix) && return "/" * HTTP.URIs.unescapeuri(uri[length(prefix) + 1:end])
    end
    nothing
end

# --- A cancel ----------------------------------------------------------------

# A cancel of the child session of a subagent stops that subagent with the
# control request `stop_task`, and the prompt of its session goes on. A stop
# that `claude` refuses is logged.
function ACP.receive_notification(agent::ClaudeCodeAgent, notification::ACP.CancelNotification, connection)
    session = lock(() -> get(agent.sessions, notification.session_id, nothing), agent.lock)
    session === nothing && return _stop_subagent!(agent, notification.session_id)
    process, requests = lock(session.lock) do
        session.is_prompting || return (nothing, nothing)
        session.is_cancelled = true
        session.process, copy(session.waiting_permissions)
    end
    requests === nothing && return nothing
    foreach(_cancel_quietly!, requests)
    process === nothing || interrupt_claude!(process)
    nothing
end

# Stop the subagent whose child session has the id `task_id`, when it runs. A
# notification must not wait, so a task of its own waits for the answer.
function _stop_subagent!(agent::ClaudeCodeAgent, task_id::AbstractString)
    for session in lock(() -> collect(values(agent.sessions)), agent.lock)
        process = lock(() -> haskey(session.translation.subagents, task_id) ? session.process : nothing, session.lock)
        process === nothing && continue
        errormonitor(@async begin
            reason = stop_claude_task!(process, task_id)
            reason === nothing || @warn "Claude Code did not stop a subagent." task_id reason
        end)
        return nothing
    end
    nothing
end

# --- A message while a turn runs ---------------------------------------------

"""
    answer_request(agent, "_session/steering", params, context)
    answer_request(agent, "_session/stop_background_task", params, context)

The extension method `_session/steering` of `claude-agent-acp`: `params` are
`{sessionId, prompt}`, as a `session/prompt` gives them, for the prompt that
runs. The message goes to `claude`, which takes it at the next call of the model
of its turn, or in a turn of its own just after that turn; the prompt that runs
ends after the turn that takes it. The answer is the outcome `injected`, or
`failed` when no prompt can take it.

The extension method `_session/stop_background_task`: `params` are
`{sessionId, taskId}`, for a background task that runs, as the notification
`_session/background_task` names it. `claude` gets the control request
`stop_task`, and the answer is an empty object when `claude` answers that it
stopped the task. An error answers a task that does not run, and a stop that
`claude` refuses or does not answer in ten seconds.
"""
function ACP.answer_request(agent::ClaudeCodeAgent, method::String, params, context)
    method == "_session/stop_background_task" && return _stop_background_task!(agent, params)
    method == "_session/steering" ||
        throw(ACP.ProtocolException(ACP.METHOD_NOT_FOUND, "The method `$(method)` is not served."))
    params isa AbstractDict ||
        throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "`_session/steering` takes `sessionId` and `prompt`."))
    session = _get_session(agent, string(get(params, "sessionId", "")))
    content = _make_claude_content(ACP.PromptRequest(Dict{String,Any}(params)).prompt)
    is_sent = lock(session.lock) do
        process = session.process
        (session.is_steerable && !session.is_cancelled && process !== nothing && is_claude_running(process)) ||
            return false
        send_user_message!(process, content)
        session.sent_messages += 1
        true
    end
    Dict{String,Any}("outcome" => is_sent ? "injected" : "failed")
end

function _stop_background_task!(agent::ClaudeCodeAgent, params)
    task_id = params isa AbstractDict ? get(params, "taskId", nothing) : nothing
    task_id isa AbstractString || throw(ACP.ProtocolException(ACP.INVALID_PARAMS,
                                        "`_session/stop_background_task` takes `sessionId` and `taskId`."))
    session = _get_session(agent, string(get(params, "sessionId", "")))
    process = lock(session.lock) do
        task = get(session.translation.background_tasks, task_id, nothing)
        process = session.process
        task !== nothing && task.status == "running" && process !== nothing && is_claude_running(process) ?
            process : nothing
    end
    process === nothing && throw(ACP.ProtocolException(ACP.INVALID_PARAMS,
                                                       "No background task `$(task_id)` runs in this session."))
    reason = stop_claude_task!(process, task_id)
    reason === nothing || throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, reason))
    Dict{String,Any}()
end

# --- A question for the person -----------------------------------------------

"""
    decide_permission!(agent, session, tool_name, input, tool_use_id) -> Dict

The decision on a call of a tool, as the permission tool answers it: the
person decides through `session/request_permission`. A tool that the person
allowed always in the session runs without a question. A call outside a
prompt, a call after a cancel, and a question without an answer are denied.
"""
function decide_permission!(agent::ClaudeCodeAgent, session::ClaudeSession, tool_name::String,
                            input::Dict{String,Any}, tool_use_id::String)
    state = lock(session.lock) do
        (session.is_cancelled || !session.is_prompting) ? :refused :
        tool_name in session.always_allowed ? :allowed : :asked
    end
    state === :refused &&
        return _make_deny_decision("No prompt runs in this session, so nobody can allow this call.")
    tool_name == "AskUserQuestion" && agent.has_question_forms && return ask_questions!(agent, session, input)
    state === :allowed && return _make_allow_decision(input)
    connection = agent.connection
    connection === nothing && return _make_deny_decision("No editor is connected, so nobody can allow this call.")
    tool_name == "ExitPlanMode" && _send_plan_mode!(connection, session, input, tool_use_id)
    tool_call = ACP.ToolCallUpdate(tool_call_id = tool_use_id, title = format_tool_title(tool_name, input),
                                   name = tool_name, kind = get_tool_kind(tool_name), status = "pending",
                                   raw_input = input)
    options = ACP.PermissionOption[
        ACP.PermissionOption(option_id = "allow_always", name = "Always allow $(tool_name)", kind = "allow_always"),
        ACP.PermissionOption(option_id = "allow", name = "Allow", kind = "allow_once"),
        ACP.PermissionOption(option_id = "reject", name = "Reject", kind = "reject_once")]
    request = try
        ACP.start_request!(connection, ACP.RequestPermissionRequest(
            session_id = session.id, tool_call = tool_call, options = options))
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
        return _make_deny_decision("No answer can come from the editor.")
    end
    # A cancel that came while the question started withdraws it at once.
    is_cancelled = lock(session.lock) do
        push!(session.waiting_permissions, request)
        session.is_cancelled
    end
    is_cancelled && _cancel_quietly!(request)
    outcome = try
        ACP.wait_for_answer(request).outcome
    catch exception
        exception isa ACP.ProtocolException || rethrow()
        :no_answer
    finally
        lock(() -> filter!(waiting -> waiting !== request, session.waiting_permissions), session.lock)
    end
    outcome === :no_answer && return _make_deny_decision("No answer came from the editor.")
    if outcome isa ACP.SelectedPermissionOutcome
        outcome.option_id == "allow_always" && lock(() -> push!(session.always_allowed, tool_name), session.lock)
        outcome.option_id in ("allow", "allow_always") && return _make_allow_decision(input)
        return _make_deny_decision("The person rejected this call.")
    end
    _make_deny_decision("The prompt was cancelled.")
end

_make_allow_decision(input::Dict{String,Any}) = Dict{String,Any}("behavior" => "allow", "updatedInput" => input)

# The plan of the plan mode, which only the question for `ExitPlanMode` holds,
# goes to an editor that takes plans with an id, before the question: in the
# session, or in the child session of the subagent that made the call.
function _send_plan_mode!(connection::ACP.Connection, session::ClaudeSession, input::Dict{String,Any},
                          tool_use_id::String)
    session_id, update = lock(session.lock) do
        translation = session.translation
        subagent_id = _find_subagent_id(translation, tool_use_id)
        subagent = subagent_id === nothing ? nothing : translation.subagents[subagent_id]
        (subagent === nothing ? session.id : subagent_id,
         make_plan_mode_update!(subagent === nothing ? translation.state : subagent.state, get(input, "plan", nothing)))
    end
    update === nothing && return nothing
    try
        ACP.send_session_update!(connection, session_id, update)
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
    end
    nothing
end

"""
    ask_questions!(agent, session, input) -> Dict

The decision on a call of `AskUserQuestion`: the questions of Claude go to the
editor as one form, through `elicitation/create`, and the answers come back in
the input of the tool, which Claude then reads. A decline, a cancel, and a form
without an answer are denied with a message for Claude.
"""
function ask_questions!(agent::ClaudeCodeAgent, session::ClaudeSession, input::Dict{String,Any})
    connection = agent.connection
    connection === nothing && return _make_deny_decision("No editor is connected, so nobody can answer.")
    questions = Dict{String,Any}[question for question in get(input, "questions", Any[]) if question isa Dict{String,Any}]
    request = try
        ACP.start_request!(connection, ACP.CreateElicitationRequestForm(
            message = length(questions) == 1 ? "Claude asks a question." : "Claude asks $(length(questions)) questions.",
            requested_schema = make_question_schema(questions), session_id = session.id))
    catch exception
        exception isa ACP.ProtocolException || exception isa Base.IOError || rethrow()
        return _make_deny_decision("No answer can come from the editor.")
    end
    # A cancel that came while the form started withdraws it at once.
    is_cancelled = lock(session.lock) do
        push!(session.waiting_permissions, request)
        session.is_cancelled
    end
    is_cancelled && _cancel_quietly!(request)
    answer = try
        ACP.wait_for_answer(request)
    catch exception
        exception isa ACP.ProtocolException || rethrow()
        nothing
    finally
        lock(() -> filter!(waiting -> waiting !== request, session.waiting_permissions), session.lock)
    end
    answer isa ACP.CreateElicitationResponseAccept || return _make_deny_decision("The person declined to answer.")
    content = get(ACP.get_json(answer), "content", nothing)
    _make_allow_decision(Dict{String,Any}("questions" => input["questions"],
                                          "answers" => read_question_answers(questions,
                                                                             content isa AbstractDict ? content : Dict{String,Any}())))
end

"""
    make_question_schema(questions) -> ACP.ElicitationSchema

The form of the questions of `AskUserQuestion`. The question `i` is the field
`question_i`, a choice of its options, or a choice of several for a
`multiSelect` question, with its header as the title and the question as the
description; and the text field `question_i_other`, for an answer in the words
of the person. No field is required, so a person can answer with the text alone.
The names keep the order of the questions in the order of the names.
"""
function make_question_schema(questions::AbstractVector)
    properties = Dict{String,Any}()
    for (index, question) in enumerate(questions)
        options = ACP.EnumOption[ACP.EnumOption(const_ = string(get(option, "label", "")),
                                                title = string(get(option, "label", "")),
                                                description = get(option, "description", nothing))
                                 for option in get(question, "options", Any[]) if option isa AbstractDict]
        title = string(get(question, "header", "Question $(index)"))
        description = string(get(question, "question", ""))
        properties["question_$(index)"] = get(question, "multiSelect", false) === true ?
            ACP.MultiSelectPropertySchema(title = title, description = description,
                                          items = ACP.TitledMultiSelectItems(any_of = options)) :
            ACP.StringPropertySchema(title = title, description = description, one_of = options)
        properties["question_$(index)_other"] =
            ACP.StringPropertySchema(title = "Other", description = "An answer in your own words to: " * description)
    end
    ACP.ElicitationSchema(type = "object", properties = properties)
end

"""
    read_question_answers(questions, content) -> Dict{String,Any}

The `answers` of `AskUserQuestion` from the values of the form: for each
question that has an answer, its text and the answer, which is the text of the
person when it is not empty, else the label of the chosen option, or the labels
of the chosen options joined with ", ".
"""
function read_question_answers(questions::AbstractVector, content::AbstractDict)
    answers = Dict{String,Any}()
    for (index, question) in enumerate(questions)
        text = string(get(question, "question", ""))
        own = get(content, "question_$(index)_other", nothing)
        chosen = get(content, "question_$(index)", nothing)
        if own isa AbstractString && !isempty(strip(own))
            answers[text] = String(strip(own))
        elseif chosen isa AbstractVector && !isempty(chosen)
            answers[text] = join(string.(chosen), ", ")
        elseif chosen isa AbstractString && !isempty(chosen)
            answers[text] = String(chosen)
        end
    end
    answers
end
_make_deny_decision(message::String) = Dict{String,Any}("behavior" => "deny", "message" => message)
