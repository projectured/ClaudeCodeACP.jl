# The translation of single stream events, without a process.

using ClaudeCodeACP: TurnState, translate_event!, format_tool_title, get_tool_kind

tool_use(name, input; id = "t1") = Dict{String,Any}("type" => "assistant", "parent_tool_use_id" => nothing,
    "message" => Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "tool_use", "id" => id,
                                                                    "name" => name, "input" => input)]))
tool_result(content; id = "t1", is_error = false, result = nothing) = Dict{String,Any}(
    "type" => "user", "parent_tool_use_id" => nothing, "tool_use_result" => result,
    "message" => Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "tool_result", "tool_use_id" => id,
                                                                    "content" => content, "is_error" => is_error)]))

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
end
