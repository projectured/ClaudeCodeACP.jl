# The permission tool: a small MCP server on the loopback address, which serves
# the tools of the agent to each `claude` of the agent. `claude` calls the
# permission tool, through `--permission-prompt-tool`, before it runs a tool that
# needs the word of the person. The bearer secret of a request names its
# session.

# The name of the server in the MCP configuration of `claude`, and its tool.
const PERMISSION_SERVER_NAME = "claude_code_acp"
const PERMISSION_TOOL = "permission"
const PERMISSION_TOOL_NAME = "mcp__$(PERMISSION_SERVER_NAME)__$(PERMISSION_TOOL)"

"""
    PermissionServer

The MCP server of the permission tool: its HTTP server on `127.0.0.1`, its
port, and four functions. `find_session(secret)` answers the session that the
secret names, or `nothing`; a request with another secret gets `401`.
`decide(session, tool_name, input, tool_use_id)` answers the JSON object of the
decision for a call of the permission tool. `list_tools(session)` answers the
other tools that the server serves to the session, as `tools/list` names them,
and `call_tool(session, name, arguments, tool_use_id)` answers the result of a
call of one of them, or `nothing` for a tool that the session does not have.
`tool_use_id` is the id of the tool call of Claude that made the call, or
empty when `claude` does not name it.
"""
mutable struct PermissionServer
    server::Any
    port::Int
    find_session::Function
    decide::Function
    list_tools::Function
    call_tool::Function
end

"""
    start_permission_server!(find_session, decide, list_tools, call_tool) -> PermissionServer

Start the server on a port that no other program holds.
"""
function start_permission_server!(find_session::Function, decide::Function, list_tools::Function,
                                  call_tool::Function)
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(last(Sockets.getsockname(listener)))
    permission = PermissionServer(nothing, port, find_session, decide, list_tools, call_tool)
    permission.server = HTTP.serve!(request -> _answer_http_request(permission, request),
                                    "127.0.0.1", port; server = listener, verbose = -1)
    permission
end

"""
    stop_permission_server!(permission)

Stop the server at once, also while a question waits for the person.
"""
stop_permission_server!(permission::PermissionServer) = (HTTP.forceclose(permission.server); nothing)

# The time in milliseconds that `claude` gives each call of the permission server,
# as the `timeout` of the server: the limit of a call that `claude` names by
# default. Without it, `claude` 2.1.309 ends a call of an HTTP server that gives no
# answer in a minute, but a question of permission waits for the person, and a
# command in the foreground runs up to ten minutes.
const PERMISSION_SERVER_CALL_MILLISECONDS = 100_000_000

"""
    make_permission_mcp_server(permission, secret) -> Dict

The entry of the MCP configuration of `claude` for the permission server, with
the secret of one session in its header, and the time that `claude` gives each
call of it, [`PERMISSION_SERVER_CALL_MILLISECONDS`](@ref).
"""
make_permission_mcp_server(permission::PermissionServer, secret::AbstractString) = Dict{String,Any}(
    "type" => "http", "url" => "http://127.0.0.1:$(permission.port)/mcp",
    "headers" => Dict{String,Any}("Authorization" => "Bearer " * secret),
    "timeout" => PERMISSION_SERVER_CALL_MILLISECONDS)

"""
    make_session_secret() -> String

A random secret of 32 bytes, as hexadecimal text.
"""
make_session_secret() = bytes2hex(rand(RandomDevice(), UInt8, 32))

"""
    is_same_secret(a, b) -> Bool

Whether two secrets are equal, in a time that does not depend on where they
differ.
"""
function is_same_secret(a::AbstractString, b::AbstractString)
    x, y = codeunits(a), codeunits(b)
    length(x) == length(y) || return false
    difference = 0x00
    for index in eachindex(x)
        difference |= x[index] ⊻ y[index]
    end
    difference == 0x00
end

# The transport is the Streamable HTTP of MCP in its simple form: each POST
# carries one JSON-RPC message, and a request gets its answer as JSON in the
# response. The server offers no stream of its own, so a GET gets 405.
function _answer_http_request(permission::PermissionServer, request::HTTP.Request)
    request.method == "POST" || return HTTP.Response(405, ["Allow" => "POST"])
    secret = _read_bearer_secret(request)
    session = secret === nothing ? nothing : permission.find_session(secret)
    session === nothing && return HTTP.Response(401)
    message = try
        JSON.parse(String(request.body); dicttype = Dict{String,Any})
    catch exception
        exception isa InterruptException && rethrow()
        return HTTP.Response(400)
    end
    message isa Dict{String,Any} || return HTTP.Response(400)
    haskey(message, "id") || return HTTP.Response(202)
    # A failure answers an error that quotes nothing of the request, whose input
    # can hold the content of a file.
    result = try
        _answer_mcp_request(permission, session, message)
    catch exception
        exception isa InterruptException && rethrow()
        @warn "The permission tool failed to answer." exception = nameof(typeof(exception))
        Dict{String,Any}("error" => Dict{String,Any}("code" => -32603, "message" => "The permission tool failed."))
    end
    HTTP.Response(200, ["Content-Type" => "application/json"],
                  JSON.json(merge(Dict{String,Any}("jsonrpc" => "2.0", "id" => message["id"]), result)))
end

function _read_bearer_secret(request::HTTP.Request)
    header = HTTP.header(request, "Authorization", "")
    startswith(header, "Bearer ") || return nothing
    String(header[8:end])
end

# The answer of one MCP request of a session, as the field `result` or `error`.
function _answer_mcp_request(permission::PermissionServer, session, message::Dict{String,Any})
    method = get(message, "method", "")
    params = get(message, "params", nothing)
    params isa Dict{String,Any} || (params = Dict{String,Any}())
    if method == "initialize"
        version = get(params, "protocolVersion", "2025-06-18")
        return Dict{String,Any}("result" => Dict{String,Any}(
            "protocolVersion" => version, "capabilities" => Dict{String,Any}("tools" => Dict{String,Any}()),
            "serverInfo" => Dict{String,Any}("name" => PERMISSION_SERVER_NAME, "version" => "0.1.0")))
    elseif method == "ping"
        return Dict{String,Any}("result" => Dict{String,Any}())
    elseif method == "tools/list"
        return Dict{String,Any}("result" => Dict{String,Any}("tools" => Any[Dict{String,Any}(
            "name" => PERMISSION_TOOL,
            "description" => "Asks the person in the editor whether a tool call may run.",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "tool_name" => Dict{String,Any}("type" => "string"),
                    "input" => Dict{String,Any}("type" => "object"),
                    "tool_use_id" => Dict{String,Any}("type" => "string")),
                "required" => Any["tool_name", "input"])), permission.list_tools(session)...]))
    elseif method == "tools/call"
        arguments = get(params, "arguments", nothing)
        arguments isa Dict{String,Any} || (arguments = Dict{String,Any}())
        name = string(get(params, "name", ""))
        if name != PERMISSION_TOOL
            result = permission.call_tool(session, name, arguments, _read_tool_use_id(params))
            result === nothing && return Dict{String,Any}("error" => Dict{String,Any}(
                "code" => -32602, "message" => "No tool `$(name)`."))
            return Dict{String,Any}("result" => result)
        end
        input = get(arguments, "input", nothing)
        decision = permission.decide(session, string(get(arguments, "tool_name", "")),
                                     input isa Dict{String,Any} ? input : Dict{String,Any}(),
                                     string(get(arguments, "tool_use_id", "")))
        return Dict{String,Any}("result" => Dict{String,Any}("content" => Any[Dict{String,Any}(
            "type" => "text", "text" => JSON.json(decision))]))
    end
    Dict{String,Any}("error" => Dict{String,Any}("code" => -32601, "message" => "No method `$(method)`."))
end

# The id of the tool call of Claude that made a call of a tool: `claude` names it
# in the `_meta` of `tools/call` as `claudecode/toolUseId`. Empty when it does
# not.
function _read_tool_use_id(params::Dict{String,Any})
    meta = get(params, "_meta", nothing)
    id = meta isa AbstractDict ? get(meta, "claudecode/toolUseId", nothing) : nothing
    id isa AbstractString ? String(id) : ""
end
