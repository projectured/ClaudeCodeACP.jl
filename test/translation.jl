# The translation of single stream events, without a process.

using ClaudeCodeACP: TurnState, translate_event!, format_tool_title, get_tool_kind, ClientFeatures,
                     SessionTranslation, translate_session_event!, end_running_tasks!

tool_use(name, input; id = "t1") = Dict{String,Any}("type" => "assistant", "parent_tool_use_id" => nothing,
    "message" => Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "tool_use", "id" => id,
                                                                    "name" => name, "input" => input)]))
tool_result(content; id = "t1", is_error = false, result = nothing) = Dict{String,Any}(
    "type" => "user", "parent_tool_use_id" => nothing, "tool_use_result" => result,
    "message" => Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "tool_result", "tool_use_id" => id,
                                                                    "content" => content, "is_error" => is_error)]))
system_event(subtype; fields...) = Dict{String,Any}("type" => "system", "subtype" => subtype,
                                                    (String(key) => value for (key, value) in fields)...)
make_subagent_start(task_id, call_id) = system_event("task_started"; task_id, tool_use_id = call_id,
    task_type = "local_agent", description = "Task " * task_id, subagent_type = "general-purpose", prompt = "Go.")

@testset "the translation of the stream" begin
    @testset "the title and the kind of a tool" begin
        @test format_tool_title("Read", Dict{String,Any}("file_path" => "/a.jl")) == "Read /a.jl"
        @test format_tool_title("Bash", Dict{String,Any}("command" => "ls")) == "ls"
        @test format_tool_title("Bash", Dict{String,Any}("command" => "ls", "description" => "List")) == "List"
        @test format_tool_title("mcp__projectured__execute_julia_code", Dict{String,Any}()) ==
              "projectured: execute_julia_code"
        @test get_tool_kind("Edit") == "edit"
        @test get_tool_kind("Grep") == "search"
        @test get_tool_kind("Something") == "other"
    end

    @testset "an edit shows its diff, and a read its location" begin
        state = TurnState()
        input = Dict{String,Any}("file_path" => "/a.jl", "old_string" => "x = 1", "new_string" => "x = 2")
        call = only(translate_event!(state, tool_use("Edit", input)))
        @test only(call.locations).path == "/a.jl"
        @test call.meta["claudeCode"]["toolName"] == "Edit"
        update = only(translate_event!(state, tool_result("ok")))
        diff = only(update.content)
        @test (diff.path, diff.old_text, diff.new_text) == ("/a.jl", "x = 1", "x = 2")
        read_call = only(translate_event!(state, tool_use("Read", Dict{String,Any}("file_path" => "/b.jl"); id = "t2")))
        @test read_call.kind == "read"
        text = only(translate_event!(state, tool_result(Any[Dict{String,Any}("type" => "text", "text" => "line")];
                                                        id = "t2")))
        @test only(text.content).content.text == "line"
        # A read of a file gives its text as a resource, without the numbers of
        # its lines, and with the media type of its extension.
        translate_event!(state, tool_use("Read", Dict{String,Any}("file_path" => "/c.md"); id = "t3"))
        read_file = Dict{String,Any}("type" => "text", "file" => Dict{String,Any}(
            "filePath" => "/c.md", "content" => "# Title\n", "numLines" => 2, "startLine" => 1, "totalLines" => 2))
        update = only(translate_event!(state, tool_result("1\t# Title\n2\t"; id = "t3", result = read_file)))
        resource = only(update.content).content.resource
        @test (resource.uri, resource.mime_type, resource.text) == ("file:///c.md", "text/markdown", "# Title\n")
        @test ClaudeCodeACP.find_media_type("/d/E.JL") == "text/x-julia"
        @test ClaudeCodeACP.find_media_type("/d/e.unknown") === nothing
        # A read with no text of a file keeps the text for the model.
        translate_event!(state, tool_use("Read", Dict{String,Any}("file_path" => "/f.png"); id = "t4"))
        image = only(translate_event!(state, tool_result("[image]"; id = "t4",
                                                         result = Dict{String,Any}("type" => "image"))))
        @test only(image.content).content.text == "[image]"
    end

    @testset "a deleted task leaves the plan" begin
        state = TurnState()
        translate_event!(state, tool_use("TaskCreate", Dict{String,Any}("subject" => "A")))
        plan = last(translate_event!(state, tool_result("made"; result = Dict{String,Any}(
            "task" => Dict{String,Any}("id" => "1", "subject" => "A")))))
        @test only(plan.entries).content == "A"
        translate_event!(state, tool_use("TaskUpdate", Dict{String,Any}("taskId" => "1", "status" => "deleted"); id = "t2"))
        plan = last(translate_event!(state, tool_result("deleted"; id = "t2")))
        @test isempty(plan.entries)
    end

    @testset "the events of a subagent give no update" begin
        event = tool_use("Read", Dict{String,Any}("file_path" => "/a.jl"))
        event["parent_tool_use_id"] = "toolu_parent"
        @test isempty(translate_event!(TurnState(), event))
    end

    @testset "TodoWrite replaces the plan, which a client with plans gets with the _meta of its steps" begin
        todos = Any[Dict{String,Any}("content" => "Write a", "status" => "completed", "activeForm" => "Writing a"),
                    Dict{String,Any}("content" => "Write b", "status" => "in_progress", "activeForm" => "Writing b")]
        state = TurnState()
        translate_event!(state, tool_use("TodoWrite", Dict{String,Any}("todos" => todos)))
        plan = last(translate_event!(state, tool_result("ok")))
        @test plan isa ACP.Plan
        @test [(entry.content, entry.status) for entry in plan.entries] == [("Write a", "completed"), ("Write b", "in_progress")]
        @test all(entry.meta === nothing for entry in plan.entries)
        state = TurnState(features = ClientFeatures(plans = true))
        translate_event!(state, tool_use("TodoWrite", Dict{String,Any}("todos" => todos)))
        update = last(translate_event!(state, tool_result("ok")))
        @test update isa ACP.PlanUpdate && update.plan isa ACP.PlanItems
        @test update.plan.plan_id == "tasks"
        @test update.plan.entries[2].meta == Dict("claudeCode" => Dict("activeForm" => "Writing b"))
        translate_event!(state, tool_use("TodoWrite", Dict{String,Any}("todos" => Any[
            Dict{String,Any}("content" => "Only", "status" => "pending")]); id = "t2"))
        update = last(translate_event!(state, tool_result("ok"; id = "t2")))
        @test [(entry.content, entry.meta) for entry in update.plan.entries] == [("Only", nothing)]
    end

    @testset "a deleted step leaves the blockers of the others" begin
        state = TurnState(features = ClientFeatures(plans = true))
        for (index, subject) in enumerate(("A", "B"))
            translate_event!(state, tool_use("TaskCreate", Dict{String,Any}("subject" => subject); id = "c$(index)"))
            translate_event!(state, tool_result("made"; id = "c$(index)", result = Dict{String,Any}(
                "task" => Dict{String,Any}("id" => string(index), "subject" => subject))))
        end
        translate_event!(state, tool_use("TaskUpdate", Dict{String,Any}("taskId" => "1", "addBlocks" => Any["2"]); id = "u1"))
        update = last(translate_event!(state, tool_result("ok"; id = "u1")))
        @test update.plan.entries[2].meta["claudeCode"] == Dict("taskId" => "2", "blockedBy" => ["1"])
        translate_event!(state, tool_use("TaskUpdate", Dict{String,Any}("taskId" => "1", "status" => "deleted"); id = "u2"))
        update = last(translate_event!(state, tool_result("ok"; id = "u2")))
        @test only(update.plan.entries).meta["claudeCode"] == Dict("taskId" => "2")
    end

    @testset "the plan of ExitPlanMode goes as Markdown to a client with plans, once" begin
        state = TurnState(features = ClientFeatures(plans = true))
        input = Dict{String,Any}("plan" => "# Plan\n\n1. A")
        markdown = only(update for update in translate_event!(state, tool_use("ExitPlanMode", input))
                        if update isa ACP.PlanUpdate).plan
        @test markdown isa ACP.PlanMarkdown
        @test (markdown.plan_id, markdown.content) == ("plan-mode", "# Plan\n\n1. A")
        @test !any(update -> update isa ACP.PlanUpdate, translate_event!(state, tool_use("ExitPlanMode", input; id = "t2")))
        @test !any(update -> update isa ACP.PlanUpdate, translate_event!(TurnState(), tool_use("ExitPlanMode", input)))
    end

    @testset "a compaction, an API retry and a model fallback, for a client that takes them" begin
        events = [system_event("compact_boundary"; uuid = "c1",
                               compact_metadata = Dict{String,Any}("trigger" => "auto", "pre_tokens" => 150000)),
                  system_event("api_retry"; attempt = 2, max_retries = 10, retry_delay_ms = 2500, error_status = 529,
                               error = "overloaded"),
                  system_event("model_fallback"; trigger = "overloaded", original_model = "opus",
                               fallback_model = "sonnet", content = "Opus is overloaded.")]
        translation = SessionTranslation("s"; features = ClientFeatures(notices = true, compaction = true))
        messages = reduce(vcat, [translate_session_event!(translation, event) for event in events])
        @test first.(messages) == ["s", "s", "s"]
        compaction, retry, fallback = last.(messages)
        @test compaction isa ACP.CompactionUpdate
        @test (compaction.compaction_id, compaction.status) == ("c1", "completed")
        @test retry isa ACP.Notice
        @test (retry.severity, retry.title) == ("warning", "API retry 2 of 10")
        @test retry.description == "The request failed: overloaded (HTTP 529). The next try comes in 2.5 s."
        @test (fallback.severity, fallback.title, fallback.description) ==
              ("warning", "The model opus falls back to sonnet", "Opus is overloaded.")
        @test all(isempty(translate_session_event!(SessionTranslation("s"), event)) for event in events)
    end

    @testset "a subagent of a subagent is announced on its parent, and its messages go to its child session" begin
        translation = SessionTranslation("s"; features = ClientFeatures(subagents = true))
        call = only(translate_session_event!(translation, tool_use("Agent", Dict{String,Any}(); id = "call-outer")))
        @test first(call) == "s"
        announce, prompt = translate_session_event!(translation, make_subagent_start("outer", "call-outer"))
        @test first(announce) == "s"
        @test (last(announce).session_id, last(announce).title) == ("outer", "Task outer")
        @test first(prompt) == "outer" && last(prompt) isa ACP.UserMessageChunk && last(prompt).content.text == "Go."
        inner_call = tool_use("Agent", Dict{String,Any}(); id = "call-inner")
        inner_call["parent_tool_use_id"] = "call-outer"
        @test first(only(translate_session_event!(translation, inner_call))) == "outer"
        @test first(first(translate_session_event!(translation, make_subagent_start("inner", "call-inner")))) == "outer"
        # A task whose call no event names is announced on the session.
        @test first(first(translate_session_event!(translation, make_subagent_start("lost", "call-unknown")))) == "s"
        text = Dict{String,Any}("type" => "assistant", "parent_tool_use_id" => "call-inner", "message" => Dict{String,Any}(
            "id" => "m1", "content" => Any[Dict{String,Any}("type" => "thinking", "thinking" => "Hm."),
                                          Dict{String,Any}("type" => "text", "text" => "Done.")]))
        thought, chunk = translate_session_event!(translation, text)
        @test first(thought) == "inner" && last(thought) isa ACP.AgentThoughtChunk
        @test first(chunk) == "inner" && last(chunk) isa ACP.AgentMessageChunk
        @test (last(chunk).content.text, last(chunk).message_id) == ("Done.", "m1")
        # The end of a task makes its subagent idle once.
        ended = system_event("task_updated"; task_id = "inner", patch = Dict{String,Any}("status" => "killed"))
        idle = last(only(translate_session_event!(translation, ended)))
        @test idle.state isa ACP.IdleStateUpdate && idle.state.stop_reason == "cancelled"
        @test isempty(translate_session_event!(translation, ended))
        # A client without subagents gets no announce, and no message of a subagent.
        plain = SessionTranslation("s")
        @test isempty(translate_session_event!(plain, make_subagent_start("outer", "call-outer")))
        @test isempty(translate_session_event!(plain, text))
    end

    @testset "a background task names the subagent that started it, and the end of claude ends the work" begin
        translation = SessionTranslation("s"; features = ClientFeatures(subagents = true, background_tasks = true))
        translate_session_event!(translation, tool_use("Agent", Dict{String,Any}(); id = "call-agent"))
        translate_session_event!(translation, make_subagent_start("helper", "call-agent"))
        command = tool_use("Bash", Dict{String,Any}("command" => "sleep 9", "run_in_background" => true); id = "call-bash")
        command["parent_tool_use_id"] = "call-agent"
        translate_session_event!(translation, command)
        start_task(task_id, call_id) = last(only(translate_session_event!(translation, system_event("task_started";
            task_id, tool_use_id = call_id, task_type = "local_bash", description = "Sleep"))))
        params = start_task("b1", "call-bash").params
        @test (params["sessionId"], params["subagentId"], params["status"]) == ("s", "helper", "running")
        # A task whose call no subagent made names none.
        @test !haskey(start_task("b2", "call-other").params, "subagentId")
        messages = end_running_tasks!(translation, "failed")
        idle = only(last(message) for message in messages if last(message) isa ACP.SubagentUpdate)
        @test (idle.session_id, idle.state.stop_reason) == ("helper", "cancelled")
        ended = sort([last(message).params for message in messages if !(last(message) isa ACP.SubagentUpdate)];
                     by = params -> params["taskId"])
        @test [(params["taskId"], params["status"], params["canStop"]) for params in ended] ==
              [("b1", "failed", false), ("b2", "failed", false)]
        @test all(params["endTime"] isa Integer for params in ended)
        @test isempty(end_running_tasks!(translation, "stopped"))
    end

    @testset "a session keeps nothing of the subagents and the background tasks that ended" begin
        translation = SessionTranslation("s"; features = ClientFeatures(subagents = true, background_tasks = true))
        for index in 1:50
            call = "call-$(index)"
            translate_session_event!(translation, make_subagent_start("agent-$(index)", call))
            read = tool_use("Read", Dict{String,Any}("file_path" => "/a"); id = "read-$(index)")
            read["parent_tool_use_id"] = call
            translate_session_event!(translation, read)
            translate_session_event!(translation, system_event("task_updated"; task_id = "agent-$(index)",
                                                               patch = Dict{String,Any}("status" => "completed")))
            translate_session_event!(translation, system_event("task_notification"; task_id = "agent-$(index)",
                                                               status = "completed", summary = "Done."))
            translate_session_event!(translation, system_event("task_started"; task_id = "bash-$(index)",
                                                               tool_use_id = "b-$(index)", task_type = "local_bash"))
            translate_session_event!(translation, system_event("task_updated"; task_id = "bash-$(index)",
                patch = Dict{String,Any}("status" => "completed", "end_time" => 1)))
            translate_session_event!(translation, system_event("task_notification"; task_id = "bash-$(index)",
                                                               status = "completed", summary = "Done."))
        end
        @test isempty(translation.subagents) && isempty(translation.subagent_ids)
        @test isempty(translation.background_tasks)
        @test length(translation.ended_subagents) == 50
        # A late start of a subagent that ended announces nothing.
        @test isempty(translate_session_event!(translation, make_subagent_start("agent-1", "call-1")))
        # A late notification of a task that ended sends nothing.
        @test isempty(translate_session_event!(translation, system_event("task_notification"; task_id = "bash-1",
                                                                         status = "completed")))
        # A client without background tasks keeps none.
        plain = SessionTranslation("s")
        translate_session_event!(plain, system_event("task_started"; task_id = "b", task_type = "local_bash"))
        @test isempty(plain.background_tasks)
    end
end
