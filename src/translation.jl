# From the stream events of `claude` to the session updates of ACP: the chunks of
# text and of thinking, the tool calls and their results, the plan from the task
# tools, the commands, and the usage; and, for a client that takes them, the
# child sessions of the subagents, the background tasks, the plans with an id,
# the notices and the compactions.

"""
    ClientFeatures(; subagents, plans, notices, compaction, background_tasks)

The updates beyond version 1 of ACP that the client takes, as it advertised
them in `initialize`: the child sessions of the subagents
(`clientCapabilities.subagents`), the plans with an id (`.plan`), the notices
(`.session.notices`), the compactions (`.session.compaction`), and the extension
notification `_session/background_task` (`._meta.backgroundTasks`). A client
that advertises none of them gets the updates of version 1 only.
"""
Base.@kwdef struct ClientFeatures
    subagents::Bool = false
    plans::Bool = false
    notices::Bool = false
    compaction::Bool = false
    background_tasks::Bool = false
end

"""
    PlanStep

One step of the plan of a session, from `TaskCreate`, `TaskUpdate` or
`TodoWrite`: its id, which a step of `TodoWrite` lacks, its subject, its status
(`pending`, `in_progress` or `completed`), its description, the text that shows
while it runs (`activeForm`), and the ids of the steps that block it.
"""
mutable struct PlanStep
    id::Union{Nothing,String}
    subject::String
    status::String
    description::Union{Nothing,String}
    active_form::Union{Nothing,String}
    blocked_by::Vector{String}
end

"""
    TurnState(; features = ClientFeatures(), has_stream_events = true)

What the translation keeps across the events of a session or of a subagent: the
id of the message that streams, the tool calls by their id, the steps of the
plan, the size of the context of the last request, the updates that the client
takes, whether the text comes as stream events, as for a session, or only in
whole messages, as for a subagent, and the last Markdown plan of the plan mode.
"""
mutable struct TurnState
    message_id::Union{Nothing,String}
    tool_calls::Dict{String,Tuple{String,Dict{String,Any}}}
    plan_steps::Vector{PlanStep}
    context_used::Int
    features::ClientFeatures
    has_stream_events::Bool
    plan_markdown::Union{Nothing,String}
end

TurnState(; features::ClientFeatures = ClientFeatures(), has_stream_events::Bool = true) =
    TurnState(nothing, Dict{String,Tuple{String,Dict{String,Any}}}(), PlanStep[], 0, features,
              has_stream_events, nothing)

"""
    translate_event!(state, event) -> Vector{ACP.SessionUpdate}

The session updates of one stream event of `claude`. An event of a subagent,
whose `parent_tool_use_id` is set, gives none, and so does an event that the
client does not show; [`translate_session_event!`](@ref) gives the updates of a
subagent.
"""
function translate_event!(state::TurnState, event::Dict{String,Any})
    get(event, "parent_tool_use_id", nothing) === nothing || return ACP.SessionUpdate[]
    _translate_message_event!(state, event)
end

# The updates of a stream event, a message of the assistant, or a message of
# tool results, of a session or of a subagent. A subagent streams no events, so
# the text and the thinking of its whole messages become the chunks.
function _translate_message_event!(state::TurnState, event::Dict{String,Any})
    updates = ACP.SessionUpdate[]
    type = get(event, "type", nothing)
    if type == "stream_event"
        state.has_stream_events && _translate_stream_event!(updates, state, get(event, "event", Dict{String,Any}()))
    elseif type == "assistant"
        message = get(event, "message", nothing)
        id = message isa AbstractDict ? get(message, "id", nothing) : nothing
        message_id = id isa AbstractString ? String(id) : nothing
        for block in _get_content_blocks(event)
            kind = get(block, "type", nothing)
            if kind == "tool_use"
                push!(updates, _make_tool_call!(state, block))
                if get(block, "name", nothing) == "ExitPlanMode"
                    input = get(block, "input", nothing)
                    update = make_plan_mode_update!(state, input isa AbstractDict ? get(input, "plan", nothing) : nothing)
                    update === nothing || push!(updates, update)
                end
            elseif !state.has_stream_events && kind in ("text", "thinking")
                text = string(get(block, kind, ""))
                isempty(text) && continue
                push!(updates, kind == "text" ?
                    ACP.AgentMessageChunk(content = ACP.TextContent(text = text), message_id = message_id) :
                    ACP.AgentThoughtChunk(content = ACP.TextContent(text = text), message_id = message_id))
            end
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
    elseif !is_error && name == "Read" && (resource = make_read_resource(tool_use_result)) !== nothing
        push!(content, ACP.Content(content = ACP.EmbeddedResource(resource = resource)))
    else
        text = _format_result_text(get(block, "content", nothing))
        isempty(text) || push!(content, ACP.Content(content = ACP.TextContent(text = text)))
    end
    updates = ACP.SessionUpdate[ACP.ToolCallUpdate(tool_call_id = id, status = is_error ? "failed" : "completed",
                                                   content = content)]
    is_error || _update_plan_steps!(state, name, input, tool_use_result) &&
        push!(updates, state.features.plans ? make_plan_update(state) : make_plan(state))
    updates
end

"""
    make_read_resource(tool_use_result) -> Union{ACP.TextResourceContents,Nothing}

The text of a file that the tool `Read` gave, as a resource of ACP: the text as
it is in the file, the `file://` uri of its path, and the media type that the
extension of the path names. Claude Code reports the read in `tool_use_result`
without the numbers that the text for the model has on each line. `nothing` for
a read of another kind, such as an image, which keeps its text.
"""
function make_read_resource(tool_use_result)
    tool_use_result isa AbstractDict && get(tool_use_result, "type", nothing) == "text" || return nothing
    file = get(tool_use_result, "file", nothing)
    file isa AbstractDict || return nothing
    path = get(file, "filePath", nothing)
    text = get(file, "content", nothing)
    (path isa AbstractString && text isa AbstractString) || return nothing
    ACP.TextResourceContents(uri = "file://" * path, mime_type = find_media_type(path), text = text)
end

# The media types of the extensions of the files that an editor can show as more
# than text.
const MEDIA_TYPES = Dict(
    ".md" => "text/markdown", ".markdown" => "text/markdown", ".jl" => "text/x-julia",
    ".json" => "application/json", ".xml" => "application/xml", ".yaml" => "application/yaml",
    ".yml" => "application/yaml", ".toml" => "application/toml", ".csv" => "text/csv",
    ".html" => "text/html", ".py" => "text/x-python", ".txt" => "text/plain")

"""
    find_media_type(path) -> Union{String,Nothing}

The media type that the extension of `path` names, or `nothing` for an extension
that `MEDIA_TYPES` does not hold.
"""
find_media_type(path::AbstractString) = get(MEDIA_TYPES, lowercase(last(splitext(path))), nothing)

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

# The statuses of a plan step that ACP names.
const PLAN_STEP_STATUSES = ("pending", "in_progress", "completed")

# The task tools keep the plan: `TaskCreate` adds a step, whose id its result
# gives, and `TaskUpdate` changes its status, its texts and its blockers. A
# status `deleted` removes it. `TodoWrite` replaces the whole plan with its
# `todos`. Answers whether the plan changed.
function _update_plan_steps!(state::TurnState, name::AbstractString, input::Dict{String,Any}, result)
    if name == "TaskCreate"
        task = result isa AbstractDict ? get(result, "task", nothing) : nothing
        task isa AbstractDict || return false
        subject = string(get(task, "subject", get(input, "subject", "")))
        push!(state.plan_steps, PlanStep(string(get(task, "id", "")), subject, "pending", _get_text(input, "description"),
                                         _get_text(input, "activeForm"), String[]))
        return true
    elseif name == "TaskUpdate"
        id = string(get(input, "taskId", ""))
        index = findfirst(step -> step.id == id, state.plan_steps)
        index === nothing && return false
        step = state.plan_steps[index]
        status = get(input, "status", nothing)
        if status == "deleted"
            deleteat!(state.plan_steps, index)
            foreach(other -> filter!(!=(id), other.blocked_by), state.plan_steps)
            return true
        end
        status in PLAN_STEP_STATUSES && (step.status = status)
        step.subject = something(_get_text(input, "subject"), step.subject)
        step.description = something(_get_text(input, "description"), Some(step.description))
        step.active_form = something(_get_text(input, "activeForm"), Some(step.active_form))
        for blocker in _get_texts(input, "addBlockedBy")
            blocker in step.blocked_by || push!(step.blocked_by, blocker)
        end
        for blocked in _get_texts(input, "addBlocks")
            other = findfirst(other -> other.id == blocked, state.plan_steps)
            other === nothing || id in state.plan_steps[other].blocked_by ||
                push!(state.plan_steps[other].blocked_by, id)
        end
        return true
    elseif name == "TodoWrite"
        todos = get(input, "todos", nothing)
        todos isa AbstractVector || return false
        empty!(state.plan_steps)
        for todo in todos
            todo isa AbstractDict || continue
            status = get(todo, "status", nothing)
            push!(state.plan_steps, PlanStep(_get_text(todo, "id"), string(get(todo, "content", "")),
                                             status in PLAN_STEP_STATUSES ? status : "pending", nothing,
                                             _get_text(todo, "activeForm"), String[]))
        end
        return true
    end
    false
end

# The text at `key` of a JSON object, or `nothing` for no text or an empty one.
function _get_text(object::AbstractDict, key::String)
    value = get(object, key, nothing)
    value isa AbstractString && !isempty(value) ? String(value) : nothing
end

# The texts of the list at `key` of a JSON object; a number in it counts as its
# text.
function _get_texts(object::AbstractDict, key::String)
    values = get(object, key, nothing)
    values isa AbstractVector || return String[]
    String[string(value) for value in values if value isa Union{AbstractString,Integer}]
end

"""
    make_plan(state) -> ACP.Plan

The plan of version 1 of ACP: the subject and the status of each step.
"""
make_plan(state::TurnState) = ACP.Plan(entries = ACP.PlanEntry[
    ACP.PlanEntry(content = step.subject, priority = "medium", status = step.status) for step in state.plan_steps])

"""
    make_plan_update(state) -> ACP.PlanUpdate

The plan of the steps as a `plan_update` of the type `items` with the id
`tasks`. The `_meta.claudeCode` of each entry holds the keys `taskId`,
`description`, `activeForm` and `blockedBy` that the step has.
"""
make_plan_update(state::TurnState) = ACP.PlanUpdate(plan = ACP.PlanItems(plan_id = "tasks", entries = ACP.PlanEntry[
    ACP.PlanEntry(content = step.subject, priority = "medium", status = step.status, meta = _make_step_meta(step))
    for step in state.plan_steps]))

function _make_step_meta(step::PlanStep)
    fields = Dict{String,Any}()
    step.id === nothing || (fields["taskId"] = step.id)
    step.description === nothing || (fields["description"] = step.description)
    step.active_form === nothing || (fields["activeForm"] = step.active_form)
    isempty(step.blocked_by) || (fields["blockedBy"] = copy(step.blocked_by))
    isempty(fields) ? nothing : Dict{String,Any}("claudeCode" => fields)
end

"""
    make_plan_mode_update!(state, plan) -> Union{ACP.PlanUpdate,Nothing}

The Markdown plan of the plan mode, the input `plan` of `ExitPlanMode`, as a
`plan_update` of the type `markdown` with the id `plan-mode`. `nothing` for a
client that takes no plan with an id, for a plan that is no text, and for the
plan that went last.
"""
function make_plan_mode_update!(state::TurnState, plan)
    (state.features.plans && plan isa AbstractString && !isempty(plan) && plan != state.plan_markdown) ||
        return nothing
    state.plan_markdown = String(plan)
    ACP.PlanUpdate(plan = ACP.PlanMarkdown(plan_id = "plan-mode", content = state.plan_markdown))
end

# --- The subagents and the background tasks -----------------------------------

"""
    Subagent

A subagent of a session that runs, as a child session of ACP: its task id, which
is also the session id of the child, the session id of its parent, the
translation of its messages, and the fields of `_meta.claudeCode` of its
updates.
"""
mutable struct Subagent
    task_id::String
    parent_id::String
    state::TurnState
    fields::Dict{String,Any}
end

"""
    BackgroundTask

Work that `claude` started and that runs after the call that started it, such as
a command with `run_in_background`: its task id, its kind (the `task_type` of
`claude`), its title, its status (`running`, `completed`, `failed` or
`stopped`), the id of the tool call that started it, the task id of the
subagent that made that call, the `file://` uri of its output, its summary, the
times of its start and its end in milliseconds since 1970, and the params of
`_session/background_task` that went to the client last.
"""
mutable struct BackgroundTask
    task_id::String
    kind::String
    title::String
    status::String
    tool_call_id::Union{Nothing,String}
    subagent_id::Union{Nothing,String}
    output_uri::Union{Nothing,String}
    summary::Union{Nothing,String}
    start_time::Int
    end_time::Union{Nothing,Int}
    sent::Dict{String,Any}
end

"""
    BackgroundTaskNotification

The extension notification `_session/background_task` with its `params`: the
`sessionId` and the `taskId` of one background task, and the keys of its state
that changed since its last notification, which are all of them in its first.
"""
struct BackgroundTaskNotification
    params::Dict{String,Any}
end

"""
    SessionTranslation(session_id; features = ClientFeatures())

What the translation keeps for one session: its id, the translation of its own
messages, its subagents that run by their task id, the task id of each of them
by the id of the `Agent` call that started it, the session id of the parent of
each subagent that ended, by its task id, and its background tasks by their
task id until their last notification. A subagent or a background task that
ended keeps nothing else, and the end of its `claude` forgets it all.
"""
mutable struct SessionTranslation
    session_id::String
    state::TurnState
    subagents::Dict{String,Subagent}
    subagent_ids::Dict{String,String}
    ended_subagents::Dict{String,String}
    background_tasks::Dict{String,BackgroundTask}
end

SessionTranslation(session_id::String; features::ClientFeatures = ClientFeatures()) =
    SessionTranslation(session_id, TurnState(; features), Dict{String,Subagent}(), Dict{String,String}(),
                       Dict{String,String}(), Dict{String,BackgroundTask}())

"""
    translate_session_event!(translation, event) -> Vector{Pair{String,Any}}

What one event of `claude` sends to the client, as `session_id => message`: an
`ACP.SessionUpdate` of the session or of one of its subagents, or a
[`BackgroundTaskNotification`](@ref). An event of a subagent goes to its child
session, through the same translation as an event of the session. The task
events announce a subagent on its parent and change its state, or change a
background task; `compact_boundary`, `api_retry` and `model_fallback` give a
compaction and notices. Each of these goes only to a client that takes it.
"""
function translate_session_event!(translation::SessionTranslation, event::Dict{String,Any})
    messages = Pair{String,Any}[]
    parent_tool_use_id = get(event, "parent_tool_use_id", nothing)
    if get(event, "type", nothing) == "system"
        _translate_system_event!(messages, translation, event)
    elseif parent_tool_use_id === nothing
        for update in translate_event!(translation.state, event)
            push!(messages, translation.session_id => update)
        end
    else
        task_id = get(translation.subagent_ids, string(parent_tool_use_id), nothing)
        subagent = task_id === nothing ? nothing : get(translation.subagents, task_id, nothing)
        subagent === nothing && return messages
        for update in _translate_message_event!(subagent.state, event)
            push!(messages, subagent.task_id => update)
        end
    end
    messages
end

function _translate_system_event!(messages, translation::SessionTranslation, event::Dict{String,Any})
    features = translation.state.features
    subtype = get(event, "subtype", nothing)
    task_id = string(get(event, "task_id", ""))
    if subtype == "task_started" && !isempty(task_id)
        if get(event, "task_type", nothing) == "local_agent"
            features.subagents && !haskey(translation.ended_subagents, task_id) &&
                _start_subagent!(messages, translation, task_id, event)
        elseif features.background_tasks
            tool_use_id = _get_text(event, "tool_use_id")
            task = BackgroundTask(task_id, string(get(event, "task_type", "")), string(get(event, "description", "")),
                                  "running", tool_use_id, _find_subagent_id(translation, tool_use_id), nothing,
                                  nothing, _read_time(get(event, "start_time", nothing)), nothing, Dict{String,Any}())
            translation.background_tasks[task_id] = task
            _push_background_task!(messages, translation, task)
        end
    elseif subtype in ("task_progress", "task_updated", "task_notification")
        if haskey(translation.subagents, task_id)
            _update_subagent!(messages, translation, translation.subagents[task_id], subtype, event)
        elseif haskey(translation.ended_subagents, task_id)
            # A late event of a subagent that ended gives only its new usage
            # and summary.
            fields = Dict{String,Any}()
            _read_task_fields!(fields, event) && push!(messages, translation.ended_subagents[task_id] =>
                ACP.SubagentUpdate(session_id = task_id, meta = Dict{String,Any}("claudeCode" => fields)))
        elseif haskey(translation.background_tasks, task_id)
            _update_background_task!(messages, translation, translation.background_tasks[task_id], subtype, event)
        end
    elseif subtype == "compact_boundary" && features.compaction
        id = _get_text(event, "uuid")
        id === nothing ||
            push!(messages, translation.session_id => ACP.CompactionUpdate(compaction_id = id, status = "completed"))
    elseif subtype == "api_retry" && features.notices
        push!(messages, translation.session_id => ACP.Notice(severity = "warning",
            title = "API retry $(_format_count(get(event, "attempt", nothing))) of " *
                    _format_count(get(event, "max_retries", nothing)),
            description = _format_retry(event)))
    elseif subtype == "model_fallback" && features.notices
        original = _get_text(event, "original_model")
        fallback = _get_text(event, "fallback_model")
        push!(messages, translation.session_id => ACP.Notice(severity = "warning",
            title = original === nothing || fallback === nothing ? "The model falls back" :
                    "The model $(original) falls back to $(fallback)",
            description = something(_get_text(event, "content"), _get_text(event, "trigger"), Some(nothing))))
    end
    nothing
end

# A subagent announces its child session on its parent: the session, or the
# subagent whose `Agent` call started it. Its prompt goes into the child session
# as the message of the user.
function _start_subagent!(messages, translation::SessionTranslation, task_id::String, event::Dict{String,Any})
    tool_use_id = _get_text(event, "tool_use_id")
    parent_id = something(_find_subagent_id(translation, tool_use_id), translation.session_id)
    translation.subagents[task_id] = Subagent(task_id, parent_id,
        TurnState(features = translation.state.features, has_stream_events = false), Dict{String,Any}())
    tool_use_id === nothing || (translation.subagent_ids[tool_use_id] = task_id)
    push!(messages, parent_id => ACP.SubagentUpdate(
        session_id = task_id, title = _get_text(event, "description"), description = _get_text(event, "subagent_type"),
        state = ACP.RunningStateUpdate(),
        capabilities = ACP.SubagentSessionCapabilities(cancel = ACP.SessionCancelCapabilities())))
    prompt = _get_text(event, "prompt")
    prompt === nothing || push!(messages, task_id => ACP.UserMessageChunk(content = ACP.TextContent(text = prompt)))
    nothing
end

# The task id of the subagent whose message holds the tool call `tool_use_id`,
# or `nothing` for a call of the session and for a call that no event named.
_find_subagent_id(translation::SessionTranslation, tool_use_id) = tool_use_id === nothing ? nothing :
    findfirst(subagent -> haskey(subagent.state.tool_calls, tool_use_id), translation.subagents)

"""
    end_running_tasks!(translation, status) -> Vector{Pair{String,Any}}

The messages that end the work that still runs when the `claude` that holds it
ends, as [`translate_session_event!`](@ref) gives them: each subagent that runs
goes idle with the stop reason `cancelled`, and each background task that runs
gets the status `status`, `stopped` or `failed`, and its end time. Each goes only
to a client that takes it. The translation then forgets the subagents and the
background tasks of that `claude`.
"""
function end_running_tasks!(translation::SessionTranslation, status::String)
    messages = Pair{String,Any}[]
    for subagent in values(translation.subagents)
        push!(messages, subagent.parent_id => ACP.SubagentUpdate(
            session_id = subagent.task_id, state = ACP.IdleStateUpdate(stop_reason = "cancelled")))
    end
    for task in values(translation.background_tasks)
        task.status == "running" || continue
        task.status = status
        task.end_time = something(task.end_time, _read_time(nothing))
        _push_background_task!(messages, translation, task)
    end
    empty!(translation.subagents)
    empty!(translation.subagent_ids)
    empty!(translation.ended_subagents)
    empty!(translation.background_tasks)
    messages
end

# A progress keeps the subagent running; the end of its task, from
# `task_updated` or `task_notification`, makes it idle, and the translation
# forgets it but for the session id of its parent. The usage, the last tool and
# the summary go in `_meta.claudeCode`, each update with all of them.
function _update_subagent!(messages, translation::SessionTranslation, subagent::Subagent, subtype::String,
                           event::Dict{String,Any})
    is_changed = _read_task_fields!(subagent.fields, event)
    patch = get(event, "patch", nothing)
    status = subtype == "task_notification" ? get(event, "status", nothing) :
             subtype == "task_updated" && patch isa AbstractDict ? get(patch, "status", nothing) : nothing
    state = nothing
    if subtype == "task_progress"
        state = ACP.RunningStateUpdate()
    elseif status in ("completed", "failed", "killed", "stopped")
        state = ACP.IdleStateUpdate(stop_reason = status == "completed" ? "end_turn" :
                                                  status == "failed" ? nothing : "cancelled")
        delete!(translation.subagents, subagent.task_id)
        filter!(pair -> last(pair) != subagent.task_id, translation.subagent_ids)
        translation.ended_subagents[subagent.task_id] = subagent.parent_id
    end
    (state === nothing && !is_changed) && return nothing
    push!(messages, subagent.parent_id => ACP.SubagentUpdate(
        session_id = subagent.task_id, state = state,
        meta = isempty(subagent.fields) ? nothing : Dict{String,Any}("claudeCode" => copy(subagent.fields))))
    nothing
end

# The usage, the last tool and the summary of a task event into `fields`, as
# `usage` (`totalTokens`, `toolUses`, `durationMs`), `lastToolName` and
# `summary`. Answers whether a field changed.
function _read_task_fields!(fields::Dict{String,Any}, event::Dict{String,Any})
    before = copy(fields)
    usage = get(event, "usage", nothing)
    if usage isa AbstractDict
        counts = Dict{String,Any}()
        for (key, name) in ("total_tokens" => "totalTokens", "tool_uses" => "toolUses", "duration_ms" => "durationMs")
            value = get(usage, key, nothing)
            value isa Real && (counts[name] = _read_count(value))
        end
        isempty(counts) || (fields["usage"] = counts)
    end
    tool = _get_text(event, "last_tool_name")
    tool === nothing || (fields["lastToolName"] = tool)
    summary = _get_text(event, "summary")
    summary === nothing || (fields["summary"] = summary)
    fields != before
end

function _update_background_task!(messages, translation::SessionTranslation, task::BackgroundTask,
                                  subtype::String, event::Dict{String,Any})
    if subtype == "task_updated"
        patch = get(event, "patch", nothing)
        patch isa AbstractDict || return nothing
        status = get(patch, "status", nothing)
        status isa AbstractString && (task.status = _get_background_status(status))
        end_time = get(patch, "end_time", nothing)
        end_time isa Real && (task.end_time = _read_count(end_time))
        task.title = something(_get_text(patch, "description"), task.title)
    elseif subtype == "task_notification"
        status = get(event, "status", nothing)
        status isa AbstractString && (task.status = _get_background_status(status))
        output_file = _get_text(event, "output_file")
        output_file === nothing || (task.output_uri = "file://" * output_file)
        task.summary = something(_get_text(event, "summary"), Some(task.summary))
        task.status == "running" || task.end_time !== nothing || (task.end_time = _read_time(nothing))
    else
        return nothing
    end
    _push_background_task!(messages, translation, task)
    # A notification is the last word of `claude` on a task.
    subtype == "task_notification" && delete!(translation.background_tasks, task.task_id)
    nothing
end

# The status of a background task from the status of `claude`: a killed task
# counts as stopped, and a pending one as running.
_get_background_status(status::AbstractString) =
    status in ("completed", "failed") ? String(status) : status in ("killed", "stopped") ? "stopped" : "running"

# The notification of the keys of the state of a task that changed since its
# last notification, or none when no key changed.
function _push_background_task!(messages, translation::SessionTranslation, task::BackgroundTask)
    translation.state.features.background_tasks || return nothing
    state = Dict{String,Any}("kind" => task.kind, "title" => task.title, "status" => task.status,
                             "startTime" => task.start_time, "canStop" => task.status == "running")
    task.tool_call_id === nothing || (state["toolCallId"] = task.tool_call_id)
    task.subagent_id === nothing || (state["subagentId"] = task.subagent_id)
    task.output_uri === nothing || (state["outputUri"] = task.output_uri)
    task.summary === nothing || (state["summary"] = task.summary)
    task.end_time === nothing || (state["endTime"] = task.end_time)
    params = Dict{String,Any}(key => value for (key, value) in state
                              if !haskey(task.sent, key) || task.sent[key] != value)
    isempty(params) && return nothing
    task.sent = state
    params["sessionId"] = translation.session_id
    params["taskId"] = task.task_id
    push!(messages, translation.session_id => BackgroundTaskNotification(params))
    nothing
end

# A time in milliseconds since 1970: `value` when it is a number, else now.
_read_time(value) = value isa Real ? _read_count(value) : round(Int, time() * 1000)

_format_count(value) = value isa Real ? string(_read_count(value)) : "?"

# The description of an `api_retry`: the kind of the error, its HTTP status, and
# the time until the next try.
function _format_retry(event::Dict{String,Any})
    kind = something(_get_text(event, "error"), "error")
    status = get(event, "error_status", nothing)
    delay = get(event, "retry_delay_ms", nothing)
    text = "The request failed: " * kind * (status isa Real ? " (HTTP $(_read_count(status)))." : ".")
    delay isa Real ? text * " The next try comes in $(round(delay / 1000; digits = 1)) s." : text
end
