# A fake `claude` in the test process. It answers each user message of the
# agent with the events of the next turn of its script, after its echo when the
# agent started it with `--replay-user-messages`. The fakes of one starter
# share the script, so a `claude` that the agent starts again goes on with the
# next turn. In a turn, the event
# `{"type": "_wait_for_interrupt"}` waits for the interrupt message of the
# agent, `{"type": "_call"}` calls `on_call(fake)`, so a test can act as
# `claude` during a turn, and `{"type": "_exit"}` ends the fake. The events of a
# turn after its `result` are a turn that `claude` starts by itself, with no
# message of the agent. The fake answers the control request `stop_task` with a
# `control_response`: a success, or the error `stop_error`.

const JSON = ClaudeCodeACP.JSON
const HTTP = ClaudeCodeACP.HTTP

mutable struct FakeClaude
    arguments::Vector{String}
    directory::String
    to_claude::Base.BufferStream
    from_claude::Base.BufferStream
    turns::Vector{Vector{Dict{String,Any}}}
    next_turn::Base.RefValue{Int}
    received::Vector{Dict{String,Any}}
    interrupts::Channel{Bool}
    on_call::Function
    stop_error::Union{Nothing,String}
end

read_recorded(name) = Dict{String,Any}[JSON.parse(line; dicttype = Dict{String,Any})
                                       for line in eachline(joinpath(@__DIR__, "recorded", name))]

"""
    make_fake_starter(turns; on_call, fakes, gate, process_id, stop_error) -> Function

A `start_claude` for `AgentSettings`: each start makes a `FakeClaude` with the
script `turns` and pushes it to `fakes`. Its `ClaudeProcess` has the id
`process_id`, which no process has, and no `Base.Process`, so no signal goes
to that id.
"""
function make_fake_starter(turns; on_call::Function = fake -> nothing, fakes::Vector{FakeClaude} = FakeClaude[],
                           gate::Union{Nothing,Channel} = nothing, process_id::Integer = 0,
                           stop_error::Union{Nothing,String} = nothing)
    script = [copy(turn) for turn in turns]
    next_turn = Ref(0)
    (arguments, directory; capabilities = String[]) -> begin
        # A test can hold a start until it puts into `gate`.
        gate === nothing || take!(gate)
        fake = FakeClaude(arguments, directory, Base.BufferStream(), Base.BufferStream(),
                          script, next_turn, Dict{String,Any}[], Channel{Bool}(Inf), on_call, stop_error)
        push!(fakes, fake)
        messages = Channel{Dict{String,Any}}(Inf)
        errormonitor(@async _read_fake_input(fake, messages))
        errormonitor(@async _play_fake_turns(fake, messages))
        claude = ClaudeCodeACP.open_claude_process((fake.to_claude, fake.from_claude); capabilities)
        claude.process_id = Int32(process_id)
        claude
    end
end

function _read_fake_input(fake::FakeClaude, messages::Channel)
    try
        for line in eachline(fake.to_claude)
            message = JSON.parse(line; dicttype = Dict{String,Any})
            push!(fake.received, message)
            if get(message, "type", nothing) == "control_request"
                subtype = get(message["request"], "subtype", nothing)
                subtype == "interrupt" && put!(fake.interrupts, true)
                subtype == "stop_task" && _answer_fake_stop(fake, message["request_id"])
            else
                put!(messages, message)
            end
        end
    finally
        close(messages)
    end
end

function _answer_fake_stop(fake::FakeClaude, request_id)
    response = fake.stop_error === nothing ?
        Dict{String,Any}("subtype" => "success", "request_id" => request_id, "response" => Dict{String,Any}()) :
        Dict{String,Any}("subtype" => "error", "request_id" => request_id, "error" => fake.stop_error)
    _write_fake_event(fake, Dict{String,Any}("type" => "control_response", "response" => response))
end

# One event on the output of the fake, in one write, so the events of two tasks
# do not mix. An output that closed takes nothing.
function _write_fake_event(fake::FakeClaude, event)
    try
        write(fake.from_claude, JSON.json(event) * "\n")
    catch exception
        exception isa Base.IOError || exception isa ArgumentError || rethrow()
    end
    nothing
end

function _play_fake_turns(fake::FakeClaude, messages::Channel)
    try
        for message in messages
            get(message, "type", nothing) == "user" || continue
            fake.next_turn[] += 1
            fake.next_turn[] <= length(fake.turns) || break
            "--replay-user-messages" in fake.arguments &&
                _write_fake_event(fake, Dict("type" => "user", "isReplay" => true,
                                             "message" => get(message, "message", nothing)))
            for event in fake.turns[fake.next_turn[]]
                kind = get(event, "type", nothing)
                if kind == "_wait_for_interrupt"
                    take!(fake.interrupts)
                elseif kind == "_call"
                    fake.on_call(fake)
                elseif kind == "_exit"
                    return
                else
                    _write_fake_event(fake, event)
                end
            end
        end
    finally
        close(fake.from_claude)
    end
end

# The MCP configuration that the agent gave the fake, in its file.
read_mcp_config_path(fake::FakeClaude) = fake.arguments[findfirst(==("--mcp-config"), fake.arguments) + 1]
read_mcp_config(fake::FakeClaude) = JSON.parse(read(read_mcp_config_path(fake), String); dicttype = Dict{String,Any})

# A folder that exists, for the sessions of the tests.
const TEST_FOLDER = mktempdir()

# A call of the permission tool, as `claude` makes it: the decision, or the
# HTTP status of a refused request.
function call_permission_tool(fake::FakeClaude, tool_name, input; secret = nothing, id = "toolu_test")
    server = read_mcp_config(fake)["mcpServers"][ClaudeCodeACP.PERMISSION_SERVER_NAME]
    authorization = secret === nothing ? server["headers"]["Authorization"] : "Bearer " * secret
    body = JSON.json(Dict("jsonrpc" => "2.0", "id" => 7, "method" => "tools/call", "params" => Dict(
        "name" => ClaudeCodeACP.PERMISSION_TOOL,
        "arguments" => Dict("tool_name" => tool_name, "input" => input, "tool_use_id" => id))))
    response = HTTP.post(server["url"], ["Authorization" => authorization, "Content-Type" => "application/json"],
                         body; status_exception = false)
    response.status == 200 || return response.status
    answer = JSON.parse(String(response.body); dicttype = Dict{String,Any})
    JSON.parse(answer["result"]["content"][1]["text"]; dicttype = Dict{String,Any})
end

# The events of a text that streams, in the shape of `--include-partial-messages`.
make_text_events(text) = Dict{String,Any}[
    Dict{String,Any}("type" => "stream_event", "event" => Dict{String,Any}(
        "type" => "content_block_start", "index" => 0,
        "content_block" => Dict{String,Any}("type" => "text", "text" => ""))),
    Dict{String,Any}("type" => "stream_event", "event" => Dict{String,Any}(
        "type" => "content_block_delta", "index" => 0,
        "delta" => Dict{String,Any}("type" => "text_delta", "text" => text)))]

# A turn that ends with a result and nothing else.
make_result_turn(text; is_error = false, subtype = "success") = Dict{String,Any}[
    Dict{String,Any}("type" => "result", "subtype" => subtype, "is_error" => is_error, "result" => text,
                     "stop_reason" => "end_turn")]
