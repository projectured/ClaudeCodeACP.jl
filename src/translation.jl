# From the stream events of `claude` to the session updates of ACP: the chunks of
# text and of thinking, the tool calls and their results, the plan from the task
# tools, the commands, and the usage.

"""
    TurnState

What the translation keeps across the events of a session: the id of the
message that streams, the tool calls by their id, the tasks of the plan, and
the size of the context of the last request.
"""
mutable struct TurnState
    message_id::Union{Nothing,String}
    tool_calls::Dict{String,Tuple{String,Dict{String,Any}}}
    tasks::Vector{Pair{String,ACP.PlanEntry}}
    context_used::Int
end

TurnState() = TurnState(nothing, Dict{String,Tuple{String,Dict{String,Any}}}(),
                        Pair{String,ACP.PlanEntry}[], 0)

"""
    translate_event!(state, event) -> Vector{ACP.SessionUpdate}

The session updates of one stream event of `claude`. An event of a subagent,
whose `parent_tool_use_id` is set, gives none, and so does an event that the
client does not show.
"""
function translate_event!(state::TurnState, event::Dict{String,Any})
    updates = ACP.SessionUpdate[]
    get(event, "parent_tool_use_id", nothing) === nothing || return updates
    type = get(event, "type", nothing)
    if type == "stream_event"
        _translate_stream_event!(updates, state, get(event, "event", Dict{String,Any}()))
    elseif type == "assistant"
        for block in _get_content_blocks(event)
            get(block, "type", nothing) == "tool_use" && push!(updates, _make_tool_call!(state, block))
        end
    elseif type == "user"
        for block in _get_content_blocks(event)
            get(block, "type", nothing) == "tool_result" || continue
            append!(updates, _make_tool_result!(state, block, get(event, "tool_use_result", nothing)))
        end
    end
    updates
end

function _translate_stream_event!(updates, state::TurnState, stream_event)
    stream_event isa AbstractDict || return
    kind = get(stream_event, "type", nothing)
    if kind == "message_start"
        message = get(stream_event, "message", Dict{String,Any}())
        id = get(message, "id", nothing)
        state.message_id = id isa AbstractString ? String(id) : nothing
        usage = get(message, "usage", nothing)
        usage isa AbstractDict && (state.context_used = _count_input_tokens(usage))
    elseif kind == "message_delta"
        usage = get(stream_event, "usage", nothing)
        usage isa AbstractDict && (state.context_used += _read_count(get(usage, "output_tokens", 0)))
    elseif kind == "content_block_delta"
        delta = get(stream_event, "delta", Dict{String,Any}())
        delta_kind = get(delta, "type", nothing)
        if delta_kind == "text_delta"
            text = string(get(delta, "text", ""))
            isempty(text) || push!(updates, ACP.AgentMessageChunk(
                content = ACP.TextContent(text = text), message_id = state.message_id))
        elseif delta_kind == "thinking_delta"
            text = string(get(delta, "thinking", ""))
            isempty(text) || push!(updates, ACP.AgentThoughtChunk(
                content = ACP.TextContent(text = text), message_id = state.message_id))
        end
    end
end

_count_input_tokens(usage) = sum(_read_count(get(usage, key, 0))
                                 for key in ("input_tokens", "cache_read_input_tokens",
                                             "cache_creation_input_tokens"))

_read_count(value) = value isa Real ? Int(round(value)) : 0

function _get_content_blocks(event)
    message = get(event, "message", nothing)
    message isa AbstractDict || return Dict{String,Any}[]
    content = get(message, "content", nothing)
    content isa AbstractVector || return Dict{String,Any}[]
    Dict{String,Any}[block for block in content if block isa Dict{String,Any}]
end

# --- Tool calls --------------------------------------------------------------

function _make_tool_call!(state::TurnState, block::Dict{String,Any})
    id = string(get(block, "id", ""))
    name = string(get(block, "name", ""))
    input = get(block, "input", nothing)
    input isa Dict{String,Any} || (input = Dict{String,Any}())
    state.tool_calls[id] = (name, input)
    path = _find_path(input)
    ACP.ToolCall(tool_call_id = id, title = format_tool_title(name, input), name = name, kind = get_tool_kind(name),
                 status = "pending", raw_input = input,
                 locations = path === nothing ? nothing : [ACP.ToolCallLocation(path = path)],
                 meta = Dict{String,Any}("claudeCode" => Dict{String,Any}("toolName" => name)))
end

function _make_tool_result!(state::TurnState, block::Dict{String,Any}, tool_use_result)
    id = string(get(block, "tool_use_id", ""))
    name, input = get(state.tool_calls, id, ("", Dict{String,Any}()))
    is_error = get(block, "is_error", false) === true
    content = ACP.ToolCallContent[]
    if !is_error && name == "Edit" && haskey(input, "file_path")
        push!(content, ACP.Diff(path = string(input["file_path"]), old_text = string(get(input, "old_string", "")),
                                new_text = string(get(input, "new_string", ""))))
    elseif !is_error && name == "Write" && haskey(input, "file_path")
        push!(content, ACP.Diff(path = string(input["file_path"]), new_text = string(get(input, "content", ""))))
    else
        text = _format_result_text(get(block, "content", nothing))
        isempty(text) || push!(content, ACP.Content(content = ACP.TextContent(text = text)))
    end
    updates = ACP.SessionUpdate[ACP.ToolCallUpdate(tool_call_id = id, status = is_error ? "failed" : "completed",
                                                   content = content)]
    is_error || _update_tasks!(state, name, input, tool_use_result) && push!(updates, make_plan(state))
    updates
end

function _format_result_text(content)
    content isa AbstractString && return String(content)
    content isa AbstractVector || return ""
    pieces = String[]
    for item in content
        item isa AbstractDict || continue
        kind = get(item, "type", nothing)
        kind == "text" && push!(pieces, string(get(item, "text", "")))
        kind == "image" && push!(pieces, "[image]")
    end
    join(pieces, '\n')
end

function _find_path(input::Dict{String,Any})
    for key in ("file_path", "notebook_path", "path")
        value = get(input, key, nothing)
        value isa AbstractString && !isempty(value) && return String(value)
    end
    nothing
end

"""
    format_tool_title(name, input) -> String

A short title for a call of the tool `name` with `input`, as an editor shows it.
"""
function format_tool_title(name::AbstractString, input::Dict{String,Any})
    field(key) = (value = get(input, key, nothing); value isa AbstractString ? String(value) : "")
    title = if name == "Bash"
        something(_find_nonempty(field("description")), _find_nonempty(field("command")), "Run a command")
    elseif name == "Read"
        "Read " * field("file_path")
    elseif name == "Edit"
        "Edit " * field("file_path")
    elseif name == "Write"
        "Write " * field("file_path")
    elseif name == "NotebookEdit"
        "Edit " * field("notebook_path")
    elseif name == "Grep"
        "Search for " * field("pattern")
    elseif name == "Glob"
        "Find " * field("pattern")
    elseif name == "WebFetch"
        "Fetch " * field("url")
    elseif name == "WebSearch"
        "Search the web for " * field("query")
    elseif name in ("Task", "Agent")
        something(_find_nonempty(field("description")), name)
    elseif name == "TaskCreate"
        "Plan: " * field("subject")
    elseif startswith(name, "mcp__")
        parts = split(name, "__"; limit = 3)
        length(parts) == 3 ? parts[2] * ": " * parts[3] : name
    else
        name
    end
    strip(title)
end

_find_nonempty(text::String) = isempty(text) ? nothing : text

"""
    get_tool_kind(name) -> String

The ACP kind of a tool of Claude Code: `read`, `edit`, `execute`, `search`,
`fetch`, `think` or `other`.
"""
get_tool_kind(name::AbstractString) =
    name == "Read" ? "read" :
    name in ("Edit", "Write", "NotebookEdit") ? "edit" :
    name == "Bash" ? "execute" :
    name in ("Grep", "Glob", "ToolSearch") ? "search" :
    name in ("WebFetch", "WebSearch") ? "fetch" :
    name in ("Task", "Agent") ? "think" : "other"

# --- The plan ----------------------------------------------------------------

# The task tools keep the plan: `TaskCreate` adds a task, whose id its result
# gives, and `TaskUpdate` changes its status. A status `deleted` removes it.
# Answers whether the plan changed.
function _update_tasks!(state::TurnState, name::AbstractString, input::Dict{String,Any}, result)
    if name == "TaskCreate"
        task = result isa AbstractDict ? get(result, "task", nothing) : nothing
        task isa AbstractDict || return false
        id = string(get(task, "id", ""))
        subject = string(get(task, "subject", get(input, "subject", "")))
        push!(state.tasks, id => ACP.PlanEntry(content = subject, priority = "medium", status = "pending"))
        return true
    elseif name == "TaskUpdate"
        id = string(get(input, "taskId", ""))
        index = findfirst(pair -> first(pair) == id, state.tasks)
        index === nothing && return false
        status = get(input, "status", nothing)
        subject = get(input, "subject", nothing)
        entry = last(state.tasks[index])
        if status == "deleted"
            deleteat!(state.tasks, index)
            return true
        end
        state.tasks[index] = id => ACP.PlanEntry(
            content = subject isa AbstractString ? subject : entry.content, priority = entry.priority,
            status = status in ("pending", "in_progress", "completed") ? status : entry.status)
        return true
    end
    false
end

make_plan(state::TurnState) = ACP.Plan(entries = ACP.PlanEntry[last(pair) for pair in state.tasks])
