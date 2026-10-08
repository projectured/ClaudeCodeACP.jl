# A fake `claude` in the test process. It answers each user message of the
# agent with the events of the next turn of its script. The fakes of one starter
# share the script, so a `claude` that the agent starts again goes on with the
# next turn. In a turn, the event
# `{"type": "_wait_for_interrupt"}` waits for the interrupt message of the
# agent, `{"type": "_call"}` calls `on_call(fake)`, so a test can act as
# `claude` during a turn, and `{"type": "_exit"}` ends the fake.

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
end

read_recorded(name) = Dict{String,Any}[JSON.parse(line; dicttype = Dict{String,Any})
                                       for line in eachline(joinpath(@__DIR__, "recorded", name))]

"""
    make_fake_starter(turns; on_call, fakes) -> Function

A `start_claude` for `AgentSettings`: each start makes a `FakeClaude` with the
script `turns` and pushes it to `fakes`.
"""
function make_fake_starter(turns; on_call::Function = fake -> nothing, fakes::Vector{FakeClaude} = FakeClaude[])
    script = [copy(turn) for turn in turns]
    next_turn = Ref(0)
    (arguments, directory) -> begin
        fake = FakeClaude(arguments, directory, Base.BufferStream(), Base.BufferStream(),
                          script, next_turn, Dict{String,Any}[], Channel{Bool}(Inf), on_call)
        push!(fakes, fake)
        messages = Channel{Dict{String,Any}}(Inf)
        errormonitor(@async _read_fake_input(fake, messages))
        errormonitor(@async _play_fake_turns(fake, messages))
        ClaudeCodeACP.open_claude_process((fake.to_claude, fake.from_claude))
    end
end

function _read_fake_input(fake::FakeClaude, messages::Channel)
    try
        for line in eachline(fake.to_claude)
            message = JSON.parse(line; dicttype = Dict{String,Any})
            push!(fake.received, message)
            if get(message, "type", nothing) == "control_request"
                put!(fake.interrupts, true)
            else
                put!(messages, message)
            end
        end
    finally
        close(messages)
    end
end

function _play_fake_turns(fake::FakeClaude, messages::Channel)
    try
        for message in messages
            get(message, "type", nothing) == "user" || continue
            fake.next_turn[] += 1
            fake.next_turn[] <= length(fake.turns) || break
            for event in fake.turns[fake.next_turn[]]
                kind = get(event, "type", nothing)
                if kind == "_wait_for_interrupt"
                    take!(fake.interrupts)
                elseif kind == "_call"
                    fake.on_call(fake)
                elseif kind == "_exit"
                    return
                else
                    write(fake.from_claude, JSON.json(event), '\n')
                end
            end
        end
    finally
        close(fake.from_claude)
    end
end

# The MCP configuration that the agent gave the fake.
function read_mcp_config(fake::FakeClaude)
    index = findfirst(==("--mcp-config"), fake.arguments)
    JSON.parse(fake.arguments[index + 1]; dicttype = Dict{String,Any})
end

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

# A turn that ends with a result and nothing else.
make_result_turn(text; is_error = false, subtype = "success") = Dict{String,Any}[
    Dict{String,Any}("type" => "result", "subtype" => subtype, "is_error" => is_error, "result" => text,
                     "stop_reason" => "end_turn")]
