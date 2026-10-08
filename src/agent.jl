# The agent: the handler of the requests of an editor, and its sessions, each
# with its own `claude` process.

"""
    AgentSettings(; claude_command, strict_mcp_config, start_claude, check_sign_in)

- `claude_command`    — the program `claude` and its first arguments.
- `strict_mcp_config` — give `claude` only the MCP servers of the editor and the
  permission tool, with `--strict-mcp-config`, and not the MCP servers and the
  connectors of the configuration of the person.
- `start_claude(arguments, directory)` — starts `claude` and answers its
  `ClaudeProcess`; a test gives a fake.
- `check_sign_in(claude_command)` — answers whether `claude` is signed in, or
  `nothing` when it can not tell.
"""
Base.@kwdef struct AgentSettings
    claude_command::Vector{String} = ["claude"]
    strict_mcp_config::Bool = false
    start_claude::Function = (arguments, directory) -> open_claude_process(Cmd(Cmd(arguments); dir = directory))
    check_sign_in::Function = check_claude_sign_in
end

"""
    ClaudeSession

One session of the agent: its id, which is also the session id of `claude`, its
folder, the MCP servers of the editor, the secret of its permission tool, its
options, its `claude` process, and the state of its turns.
"""
mutable struct ClaudeSession
    id::String
    directory::String
    mcp_servers::Vector{Any}
    secret::String
    options::Dict{String,String}
    chosen_options::Set{String}
    process::Union{Nothing,ClaudeProcess}
    has_history::Bool
    needs_restart::Bool
    title::Union{Nothing,String}
    commands::Vector{String}
    always_allowed::Set{String}
    state::TurnState
    is_prompting::Bool
    is_cancelled::Bool
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
    lock::ReentrantLock
end

ClaudeCodeAgent(settings::AgentSettings = AgentSettings()) =
    ClaudeCodeAgent(settings, Dict{String,ClaudeSession}(), nothing, nothing, ReentrantLock())

# --- The options of a session ------------------------------------------------

# Each option: its id, its name, its category, and its values with their names.
# The value "default" gives `claude` no flag, so the configuration of the person
# decides.
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

# --- The arguments of `claude` -----------------------------------------------

"""
    make_claude_arguments(agent, session) -> Vector{String}

The command line of the `claude` of a session: print mode with stream-json in
and out, the stream of partial messages, the text of the thinking, the
permission tool, the session id or the session to resume, the options that the
person chose, and the MCP servers.
"""
function make_claude_arguments(agent::ClaudeCodeAgent, session::ClaudeSession)
    servers = Dict{String,Any}()
    for server in session.mcp_servers
        config = _make_mcp_server_config(server)
        config === nothing || (servers[first(config)] = last(config))
    end
    servers[PERMISSION_SERVER_NAME] = make_permission_mcp_server(_get_permission_server!(agent), session.secret)
    arguments = String[agent.settings.claude_command..., "-p",
                       "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--include-partial-messages",
                       "--settings", JSON.json(Dict("showThinkingSummaries" => true)),
                       "--permission-prompt-tool", PERMISSION_TOOL_NAME]
    append!(arguments, session.has_history ? ["--resume", session.id] : ["--session-id", session.id])
    for option in SESSION_OPTIONS
        option.id in session.chosen_options || continue
        value = session.options[option.id]
        value == "default" && option.id != "mode" && continue
        append!(arguments, [option.flag, option.id == "mode" && value == "default" ? DEFAULT_MODE_FLAG_VALUE : value])
    end
    agent.settings.strict_mcp_config && push!(arguments, "--strict-mcp-config")
    append!(arguments, ["--mcp-config", JSON.json(Dict("mcpServers" => servers))])
    arguments
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

function _get_permission_server!(agent::ClaudeCodeAgent)
    lock(agent.lock) do
        agent.permission === nothing &&
            (agent.permission = start_permission_server(secret -> _find_session_by_secret(agent, secret),
                (session, tool_name, input, tool_use_id) ->
                    decide_permission(agent, session, tool_name, input, tool_use_id)))
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
    check_claude_sign_in(claude_command) -> Union{Bool,Nothing}

Whether `claude` is signed in, from `claude auth status --json`. Reads only its
field `loggedIn`; the rest of the status, such as the email of the account, is
neither kept nor logged. Answers `nothing` when the status does not come.
"""
function check_claude_sign_in(claude_command::Vector{String})
    output = IOBuffer()
    environment = Dict{String,String}(filter(pair -> !(first(pair) in PARENT_SESSION_VARIABLES), ENV))
    command = Cmd(Cmd([claude_command..., "auth", "status", "--json"]); env = environment, ignorestatus = true)
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
    status = try
        JSON.parse(String(take!(output)))
    catch exception
        exception isa InterruptException && rethrow()
        nothing
    end
    signed_in = status isa AbstractDict ? get(status, "loggedIn", nothing) : nothing
    signed_in isa Bool ? signed_in : nothing
end

function _check_sign_in(agent::ClaudeCodeAgent)
    agent.settings.check_sign_in(agent.settings.claude_command) === false &&
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
    _check_sign_in(agent)
    session = _open_session!(agent, string(uuid4()), request.cwd, request.mcp_servers; has_history = false)
    ACP.NewSessionResponse(session_id = session.id, config_options = make_config_options(session))
end

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.ResumeSessionRequest, context)
    agent.connection = context.connection
    _check_sign_in(agent)
    session = _open_session!(agent, request.session_id, request.cwd, something(request.mcp_servers, Any[]);
                             has_history = true)
    ACP.ResumeSessionResponse(config_options = make_config_options(session))
end

function _open_session!(agent::ClaudeCodeAgent, id::String, directory::String, mcp_servers;
                        has_history::Bool)
    isabspath(directory) || throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The folder `$(directory)` is no absolute path."))
    session = ClaudeSession(id, directory, collect(Any, mcp_servers), make_session_secret(),
                            Dict(option.id => "default" for option in SESSION_OPTIONS), Set{String}(),
                            nothing, has_history, false, nothing, String[], Set{String}(), TurnState(),
                            false, false, ACP.OutgoingRequest[], ReentrantLock())
    lock(agent.lock) do
        haskey(agent.sessions, id) && throw(ACP.ProtocolException(ACP.INVALID_PARAMS, "The session `$(id)` is open."))
        agent.sessions[id] = session
    end
    try
        _start_claude!(agent, session)
    catch
        lock(() -> delete!(agent.sessions, id), agent.lock)
        rethrow()
    end
    session
end

function _start_claude!(agent::ClaudeCodeAgent, session::ClaudeSession)
    arguments = make_claude_arguments(agent, session)
    session.process = try
        agent.settings.start_claude(arguments, session.directory)
    catch exception
        exception isa Base.IOError || rethrow()
        throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "The program `$(first(agent.settings.claude_command))` " *
                                    "can not start: $(sprint(showerror, exception)). Install Claude Code."))
    end
    session.needs_restart = false
    nothing
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

function _close_session!(session::ClaudeSession)
    requests = lock(() -> copy(session.waiting_permissions), session.lock)
    foreach(_cancel_quietly!, requests)
    process = session.process
    process === nothing || close_claude_process!(process)
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

End each session of the agent and its `claude`, and stop the permission server.
"""
function close_agent!(agent::ClaudeCodeAgent)
    sessions = lock(agent.lock) do
        sessions = collect(values(agent.sessions))
        empty!(agent.sessions)
        sessions
    end
    foreach(_close_session!, sessions)
    permission = lock(() -> (permission = agent.permission; agent.permission = nothing; permission), agent.lock)
    permission === nothing || stop_permission_server!(permission)
    nothing
end

# --- A prompt ----------------------------------------------------------------

function ACP.answer_request(agent::ClaudeCodeAgent, request::ACP.PromptRequest, context)
    session = _get_session(agent, request.session_id)
    lock(session.lock) do
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
        if session.title === nothing
            session.title = make_title(request.prompt)
            session.title === nothing ||
                ACP.send_session_update!(connection, session.id, ACP.SessionInfoUpdate(title = session.title))
        end
        send_user_message!(session.process, content)
        session.has_history = true
        ACP.PromptResponse(stop_reason = _follow_turn!(session, connection))
    finally
        lock(() -> (session.is_prompting = false), session.lock)
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
            session.is_cancelled && return "cancelled"
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
# out of the context window of the model, with the cost of the session that
# `claude` estimates.
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
    session.is_cancelled && return "cancelled"
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

The title of a session from its first prompt: the first line of its text, with
at most 80 characters.
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
            uri = block.uri
            push!(content, Dict{String,Any}("type" => "text",
                                            "text" => startswith(uri, "file://") ? "@" * uri[8:end] : uri))
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

# --- A cancel ----------------------------------------------------------------

function ACP.receive_notification(agent::ClaudeCodeAgent, notification::ACP.CancelNotification, connection)
    session = lock(() -> get(agent.sessions, notification.session_id, nothing), agent.lock)
    session === nothing && return nothing
    requests = lock(session.lock) do
        session.is_prompting || return nothing
        session.is_cancelled = true
        copy(session.waiting_permissions)
    end
    requests === nothing && return nothing
    foreach(_cancel_quietly!, requests)
    process = session.process
    process === nothing || interrupt_claude!(process)
    nothing
end

# --- A question for the person -----------------------------------------------

"""
    decide_permission(agent, session, tool_name, input, tool_use_id) -> Dict

The decision on a call of a tool, as the permission tool answers it: the
person decides through `session/request_permission`. A tool that the person
allowed always in the session runs without a question. A call outside a prompt,
and a question without an answer, are denied.
"""
function decide_permission(agent::ClaudeCodeAgent, session::ClaudeSession, tool_name::String,
                           input::Dict{String,Any}, tool_use_id::String)
    lock(() -> tool_name in session.always_allowed, session.lock) && return _allow(input)
    connection = agent.connection
    (connection === nothing || !lock(() -> session.is_prompting, session.lock)) &&
        return _deny("No prompt runs in this session, so nobody can allow this call.")
    tool_call = ACP.ToolCallUpdate(tool_call_id = tool_use_id, title = format_tool_title(tool_name, input),
                                   name = tool_name, kind = get_tool_kind(tool_name), status = "pending",
                                   raw_input = input)
    options = ACP.PermissionOption[
        ACP.PermissionOption(option_id = "allow_always", name = "Always allow $(tool_name)", kind = "allow_always"),
        ACP.PermissionOption(option_id = "allow", name = "Allow", kind = "allow_once"),
        ACP.PermissionOption(option_id = "reject", name = "Reject", kind = "reject_once")]
    request = ACP.start_request!(connection, ACP.RequestPermissionRequest(
        session_id = session.id, tool_call = tool_call, options = options))
    lock(() -> push!(session.waiting_permissions, request), session.lock)
    outcome = try
        ACP.wait_for_answer(request).outcome
    catch exception
        exception isa ACP.ProtocolException || rethrow()
        nothing
    finally
        lock(() -> filter!(waiting -> waiting !== request, session.waiting_permissions), session.lock)
    end
    if outcome isa ACP.SelectedPermissionOutcome
        outcome.option_id == "allow_always" && lock(() -> push!(session.always_allowed, tool_name), session.lock)
        outcome.option_id in ("allow", "allow_always") && return _allow(input)
        return _deny("The person rejected this call.")
    end
    _deny("The person gave no answer, because the prompt was cancelled.")
end

_allow(input::Dict{String,Any}) = Dict{String,Any}("behavior" => "allow", "updatedInput" => input)
_deny(message::String) = Dict{String,Any}("behavior" => "deny", "message" => message)
