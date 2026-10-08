# The agent: the handler of the requests of an editor, and its sessions, each
# with its own `claude` process.

"""
    AgentSettings(; claude_command, strict_mcp_config, start_claude, read_sign_in)

- `claude_command`    — the program `claude` and its first arguments.
- `strict_mcp_config` — give `claude` only the MCP servers of the editor and the
  permission tool, with `--strict-mcp-config`, and not the MCP servers and the
  connectors of the configuration of the person.
- `start_claude(arguments, directory; capabilities)` — starts `claude` and
  answers its `ClaudeProcess`; a test gives a fake.
- `read_sign_in(claude_command)` — answers whether `claude` is signed in, or
  `nothing` when it can not tell.
- `read_thinking_display(claude_command)` — answers whether `claude` takes the
  flag `--thinking-display`.
"""
Base.@kwdef struct AgentSettings
    claude_command::Vector{String} = ["claude"]
    strict_mcp_config::Bool = false
    start_claude::Function = (arguments, directory; capabilities = String[]) ->
        open_claude_process(Cmd(Cmd(arguments); dir = directory); capabilities)
    read_sign_in::Function = read_claude_sign_in
    read_thinking_display::Function = read_claude_thinking_display
end

"""
    ClaudeSession

One session of the agent: its id, which is also the session id of `claude`, its
folder, the MCP servers of the editor, the text that the editor adds to the
system prompt, the secret of its permission tool and the private folder of its
configuration, its options, its `claude` process, and the state of its turns.
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
    state::TurnState
    is_prompting::Bool
    is_cancelled::Bool
    is_closed::Bool
    waiting_permissions::Vector{ACP.OutgoingRequest}
    lock::ReentrantLock
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
    lock::ReentrantLock
end

ClaudeCodeAgent(settings::AgentSettings = AgentSettings()) =
    ClaudeCodeAgent(settings, Dict{String,ClaudeSession}(), nothing, nothing, nothing, ReentrantLock())

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
                       "--include-partial-messages",
                       "--settings", JSON.json(Dict("showThinkingSummaries" => true)),
                       "--permission-prompt-tool", PERMISSION_TOOL_NAME]
    _has_thinking_display!(agent) && append!(arguments, ["--thinking-display", "summarized"])
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
    ACP.InitializeResponse(
        protocol_version = ACP.PROTOCOL_VERSION,
        agent_capabilities = ACP.AgentCapabilities(
            load_session = false,
            prompt_capabilities = ACP.PromptCapabilities(image = false, audio = false, embedded_context = true),
            mcp_capabilities = ACP.McpCapabilities(http = true, sse = true),
            session_capabilities = ACP.SessionCapabilities(close = ACP.SessionCloseCapabilities(),
                                                           resume = ACP.SessionResumeCapabilities())),
        agent_info = ACP.Implementation(name = "claude-code-acp", title = "Claude Code",
                                        version = string(pkgversion(@__MODULE__))),
        auth_methods = ACP.AuthMethod[ACP.AuthMethodTerminal(
            id = "claude-login", name = "Sign in to Claude Code",
            description = "Run `claude auth login` in a terminal.", args = ["--login"])])
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
                            nothing, String[], has_history, false, nothing, String[], Set{String}(), TurnState(),
                            false, false, false, ACP.OutgoingRequest[], ReentrantLock())
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

# Start the `claude` of a session, in place of the one before. A session that
# closed meanwhile keeps no process: the new one ends at once. Answers whether
# the session has the new process.
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
    is_closed = lock(session.lock) do
        session.is_closed || (session.process = process; session.needs_restart = false)
        session.is_closed
    end
    is_closed && close_claude_process!(process)
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

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.PromptRequest, context)
    session = _get_session(agent, request.session_id)
    lock(session.lock) do
        session.is_closed && throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The session is closed."))
        session.is_prompting && throw(ACP.ProtocolException(ACP.INVALID_REQUEST, "A prompt runs in this session."))
        session.is_prompting = true
        session.is_cancelled = false
    end
    connection = context.connection
    try
        content = _make_claude_content(request.prompt)
        process = session.process
        if process === nothing || session.needs_restart || !is_claude_running(process)
            process === nothing || close_claude_process!(process)
            _start_claude!(agent, session)
        end
        # A cancel or a close that came during the start ends the prompt here,
        # before `claude` gets the message.
        lock(() -> session.is_cancelled, session.lock) && return ACP.PromptResponse(stop_reason = "cancelled")
        if session.title === nothing
            session.title = make_title(request.prompt)
            session.title === nothing ||
                ACP.send_session_update!(connection, session.id, ACP.SessionInfoUpdate(title = session.title))
        end
        send_user_message!(session.process, content)
        session.has_history = true
        ACP.PromptResponse(stop_reason = _follow_turn!(session, connection))
    catch
        # The events of a turn that failed must not reach the next prompt.
        session.needs_restart = true
        rethrow()
    finally
        lock(session.lock) do
            session.is_prompting = false
            empty!(session.state.tool_calls)
        end
    end
end

# The events of `claude` until the `result` of the turn, sent to the editor as
# updates. Answers the stop reason.
function _follow_turn!(session::ClaudeSession, connection::ACP.Connection)
    process = session.process
    while true
        event = take!(process.events)
        type = get(event, "type", nothing)
        if type == "process_exit"
            session.needs_restart = true
            lock(() -> session.is_cancelled, session.lock) && return "cancelled"
            throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "Claude Code ended before the end of the turn."))
        elseif type == "system" && get(event, "subtype", nothing) == "init"
            _read_init!(session, event, connection)
        elseif type == "result"
            _send_usage!(session, event, connection)
            return _read_stop_reason(session, event)
        else
            for update in translate_event!(session.state, event)
                ACP.send_session_update!(connection, session.id, update)
            end
        end
    end
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
        used = session.state.context_used, size = size,
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
# to a file becomes a mention of its path, and an embedded text becomes text
# with its address.
function _make_claude_content(prompt::AbstractVector)
    content = Dict{String,Any}[]
    for block in prompt
        if block isa ACP.TextContent
            push!(content, Dict{String,Any}("type" => "text", "text" => block.text))
        elseif block isa ACP.ResourceLink
            path = _find_file_path(block.uri)
            push!(content, Dict{String,Any}("type" => "text", "text" => path === nothing ? block.uri : "@" * path))
        elseif block isa ACP.EmbeddedResource && block.resource isa ACP.TextResourceContents
            resource = block.resource
            push!(content, Dict{String,Any}("type" => "text", "text" =>
                "<context ref=\"$(resource.uri)\">\n$(resource.text)\n</context>"))
        else
            throw(ACP.ProtocolException(ACP.INVALID_PARAMS,
                                        "This agent takes text, links and embedded text, not a $(nameof(typeof(block)))."))
        end
    end
    content
end

# The path of a `file:` URI, decoded, or `nothing` for another URI.
function _find_file_path(uri::AbstractString)
    for prefix in ("file://localhost/", "file:///")
        startswith(uri, prefix) && return "/" * HTTP.URIs.unescapeuri(uri[length(prefix) + 1:end])
    end
    nothing
end

# --- A cancel ----------------------------------------------------------------

function ACP.receive_notification(agent::ClaudeCodeAgent, notification::ACP.CancelNotification, connection)
    session = lock(() -> get(agent.sessions, notification.session_id, nothing), agent.lock)
    session === nothing && return nothing
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
    state === :allowed && return _make_allow_decision(input)
    state === :refused &&
        return _make_deny_decision("No prompt runs in this session, so nobody can allow this call.")
    connection = agent.connection
    connection === nothing && return _make_deny_decision("No editor is connected, so nobody can allow this call.")
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
_make_deny_decision(message::String) = Dict{String,Any}("behavior" => "deny", "message" => message)
