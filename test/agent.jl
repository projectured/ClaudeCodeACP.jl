# The agent through ACP, with a client of AgentClientProtocol in this process and
# a fake `claude` that plays recorded turns.

mutable struct TestClient <: ACP.ClientHandler
    updates::Vector{Any}
    questions::Vector{Any}
    choice::Union{Nothing,String}
    on_update::Function
    forms::Vector{Any}
    form_content::Any
    session_updates::Vector{Pair{String,Any}}
    notifications::Vector{Pair{String,Any}}
end

# A client that answers each permission question with `choice`, and each form
# with `form_content`, or declines it when that is `nothing`. `updates` holds the
# updates of all sessions, `session_updates` each with its session id, and
# `notifications` the extension notifications with their method.
TestClient(; choice = "allow", on_update = (client, update) -> nothing, form_content = nothing) =
    TestClient(Any[], Any[], choice, on_update, Any[], form_content, Pair{String,Any}[], Pair{String,Any}[])

function ACP.answer_request(client::TestClient, request::ACP.CreateElicitationRequest, context)
    push!(client.forms, request)
    client.form_content === nothing && return ACP.CreateElicitationResponseDecline()
    ACP.CreateElicitationResponseAccept(content = client.form_content)
end

function ACP.receive_notification(client::TestClient, notification::ACP.SessionNotification, connection)
    push!(client.updates, notification.update)
    push!(client.session_updates, notification.session_id => notification.update)
    client.on_update(client, notification.update)
end

ACP.receive_notification(client::TestClient, method::String, params, connection) =
    push!(client.notifications, method => params)

function ACP.answer_request(client::TestClient, request::ACP.RequestPermissionRequest, context)
    push!(client.questions, request)
    if client.choice === nothing
        answer = Channel{Nothing}(1)
        ACP.add_cancel_callback!(() -> put!(answer, nothing), context)
        take!(answer)
        return ACP.RequestPermissionResponse(outcome = ACP.RequestPermissionOutcomeCancelled())
    end
    ACP.RequestPermissionResponse(outcome = ACP.SelectedPermissionOutcome(option_id = client.choice))
end

# An agent with `settings`, and a client connected to it.
function open_test_agent(settings::AgentSettings; client = TestClient(), client_capabilities = nothing)
    agent = ClaudeCodeAgent(settings)
    to_agent = Base.BufferStream()
    to_client = Base.BufferStream()
    agent_connection = ACP.open_connection(agent, to_agent, to_client)
    connection = ACP.open_connection(client, to_client, to_agent)
    ACP.send_request!(connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION,
                                                        client_capabilities = client_capabilities); timeout = 10)
    (; agent, connection, agent_connection, client)
end

function close_test_agent(test)
    ACP.close_connection!(test.connection)
    close_agent!(test.agent)
end

make_test_settings(turns; thinking_display = true, kwargs...) =
    AgentSettings(; start_claude = make_fake_starter(turns; kwargs...), read_sign_in = command -> true,
                  read_thinking_display = command -> thinking_display)

open_test_session(test; mcp_servers = [], cwd = TEST_FOLDER) =
    ACP.send_request!(test.connection, ACP.NewSessionRequest(cwd = cwd, mcp_servers = mcp_servers); timeout = 10)

send_test_prompt(test, session_id, text) =
    ACP.send_request!(test.connection, ACP.PromptRequest(session_id = session_id,
                                                         prompt = [ACP.TextContent(text = text)]); timeout = 20)

collect_text(updates, type) = join(update.content.text for update in updates if update isa type)

# The text that the stream events of the session in `events` give, without the
# text of a subagent, which streams none.
collect_stream_text(events) = join(event["event"]["delta"]["text"] for event in events
    if event["type"] == "stream_event" && get(event["event"], "type", nothing) == "content_block_delta" &&
       event["event"]["delta"]["type"] == "text_delta")

# The capabilities of a client that takes every update beyond version 1 of ACP.
make_all_capabilities() = ACP.ClientCapabilities(
    subagents = ACP.SubagentCapabilities(), plan = ACP.PlanCapabilities(),
    session = ACP.ClientSessionCapabilities(notices = ACP.NoticeCapabilities(), compaction = ACP.CompactionCapabilities()),
    meta = Dict{String,Any}("backgroundTasks" => Dict{String,Any}()))

# The updates of version 1 of ACP that the recordings give.
const VERSION_1_UPDATES = Union{ACP.AgentMessageChunk,ACP.AgentThoughtChunk,ACP.ToolCall,ACP.ToolCallUpdate,ACP.Plan,
                                ACP.AvailableCommandsUpdate,ACP.ConfigOptionUpdate,ACP.SessionInfoUpdate,ACP.UsageUpdate}

wait_until(condition) = timedwait(condition, 10.0) === :ok

count_usage(client) = count(update -> update isa ACP.UsageUpdate, client.updates)

@testset "the agent" begin
    @testset "initialize names the agent and the way to sign in" begin
        agent = ClaudeCodeAgent(AgentSettings(read_sign_in = command -> true))
        to_agent, to_client = Base.BufferStream(), Base.BufferStream()
        ACP.open_connection(agent, to_agent, to_client)
        connection = ACP.open_connection(TestClient(), to_client, to_agent)
        answer = ACP.send_request!(connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION); timeout = 10)
        @test answer.protocol_version == 1
        @test answer.agent_info.name == "claude-code-acp"
        @test answer.agent_capabilities.session_capabilities.close !== nothing
        @test answer.agent_capabilities.session_capabilities.resume !== nothing
        @test answer.agent_capabilities.auth.logout !== nothing
        @test ACP.get_json(answer)["_meta"]["steering"]["supported"] === true
        # An editor that does not say that it runs a sign-in in a terminal gets no such method.
        @test isempty(answer.auth_methods)
        ACP.close_connection!(connection)

        agent = ClaudeCodeAgent(AgentSettings(read_sign_in = command -> true))
        to_agent, to_client = Base.BufferStream(), Base.BufferStream()
        ACP.open_connection(agent, to_agent, to_client)
        connection = ACP.open_connection(TestClient(), to_client, to_agent)
        answer = ACP.send_request!(connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION,
            client_capabilities = ACP.ClientCapabilities(auth = ACP.AuthCapabilities(terminal = true))); timeout = 10)
        login = only(answer.auth_methods)
        @test login isa ACP.AuthMethodTerminal
        @test login.args == ["--login"]
        ACP.close_connection!(connection)
    end

    @testset "a sign-out signs claude out, and the next prompt asks for a sign-in" begin
        fakes = FakeClaude[]
        signed_in = Ref(true)
        test = open_test_agent(AgentSettings(start_claude = make_fake_starter([make_result_turn("one")]; fakes),
                                             read_sign_in = command -> signed_in[],
                                             run_sign_out = command -> (signed_in[] = false; nothing),
                                             read_thinking_display = command -> true))
        session = open_test_session(test)
        @test send_test_prompt(test, session.session_id, "Hello.").stop_reason == "end_turn"
        ACP.send_request!(test.connection, ACP.LogoutRequest(); timeout = 10)
        @test !signed_in[]
        failure = try
            send_test_prompt(test, session.session_id, "Again.")
        catch exception
            exception
        end
        @test failure isa ACP.ProtocolException && failure.code == ACP.AUTHENTICATION_REQUIRED
        @test length(fakes) == 1
        close_test_agent(test)

        # A sign-out that fails gives its error to the editor.
        test = open_test_agent(AgentSettings(start_claude = make_fake_starter([]), read_sign_in = command -> true,
            run_sign_out = command -> throw(ACP.ProtocolException(ACP.INTERNAL_ERROR, "no sign-out"))))
        failure = try
            ACP.send_request!(test.connection, ACP.LogoutRequest(); timeout = 10)
        catch exception
            exception
        end
        @test failure isa ACP.ProtocolException && failure.message == "no sign-out"
        close_test_agent(test)
    end

    @testset "a new session starts claude with its flags and the MCP servers" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([]; fakes))
        editor = ACP.McpServerHttp(name = "projectured", url = "http://127.0.0.1:20000/mcp",
                                   headers = [ACP.HttpHeader(name = "Authorization", value = "Bearer editor")])
        tools = ACP.McpServerStdio(name = "tools", command = "/bin/tools", args = ["--a"],
                                   env = [ACP.EnvVariable(name = "X", value = "1")])
        session = open_test_session(test; mcp_servers = [editor, tools])
        fake = only(fakes)
        arguments = fake.arguments
        @test arguments[1:2] == ["claude", "-p"]
        @test arguments[findfirst(==("--session-id"), arguments) + 1] == session.session_id
        @test arguments[findfirst(==("--permission-prompt-tool"), arguments) + 1] == ClaudeCodeACP.PERMISSION_TOOL_NAME
        @test JSON.parse(arguments[findfirst(==("--settings"), arguments) + 1]) == Dict("showThinkingSummaries" => true)
        @test arguments[findfirst(==("--thinking-display"), arguments) + 1] == "summarized"
        @test !("--strict-mcp-config" in arguments)
        @test fake.directory == TEST_FOLDER
        # The secrets are in a file that only this user reads, not on the command line.
        @test filemode(read_mcp_config_path(fake)) & 0o777 == 0o600
        @test !any(argument -> occursin("Bearer", argument), arguments)
        servers = read_mcp_config(fake)["mcpServers"]
        @test servers["projectured"] == Dict{String,Any}("type" => "http", "url" => "http://127.0.0.1:20000/mcp",
                                                        "headers" => Dict{String,Any}("Authorization" => "Bearer editor"))
        @test servers["tools"] == Dict{String,Any}("type" => "stdio", "command" => "/bin/tools", "args" => Any["--a"],
                                                  "env" => Dict{String,Any}("X" => "1"))
        permission = servers[ClaudeCodeACP.PERMISSION_SERVER_NAME]
        @test startswith(permission["url"], "http://127.0.0.1:")
        @test startswith(permission["headers"]["Authorization"], "Bearer ")
        @test [option.id for option in session.config_options] == ["mode", "model", "effort"]
        close_test_agent(test)

        strict = open_test_agent(AgentSettings(start_claude = make_fake_starter([]; fakes),
                                               read_sign_in = command -> true, strict_mcp_config = true,
                                               read_thinking_display = command -> false))
        open_test_session(strict)
        @test "--strict-mcp-config" in last(fakes).arguments
        # A claude that does not take the flag does not get it.
        @test !("--thinking-display" in last(fakes).arguments)
        # A claude that does not take the flag does not get it.
        @test !("--thinking-display" in last(fakes).arguments)
        close_test_agent(strict)
    end

    @testset "the editor adds to the system prompt through the _meta of a session" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([]; fakes))
        meta = Dict("claudeCode" => Dict("options" => Dict("systemPrompt" => Dict(
            "type" => "preset", "preset" => "claude_code", "append" => "You run inside the editor."))))
        ACP.send_request!(test.connection, ACP.NewSessionRequest(cwd = TEST_FOLDER, mcp_servers = [], meta = meta);
                          timeout = 10)
        arguments = last(fakes).arguments
        path = arguments[findfirst(==("--append-system-prompt-file"), arguments) + 1]
        @test read(path, String) == "You run inside the editor."
        @test dirname(path) == dirname(read_mcp_config_path(last(fakes)))
        open_test_session(test)
        @test !("--append-system-prompt-file" in last(fakes).arguments)
        @test ClaudeCodeACP.read_system_prompt_addition(nothing) == ""
        @test ClaudeCodeACP.read_system_prompt_addition(Dict("claudeCode" => Dict("options" => 1))) == ""
        close_test_agent(test)
    end

    @testset "a prompt streams its title, commands, thinking, text and usage" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([read_recorded("thinking-and-text.jsonl")]; fakes))
        session = open_test_session(test)
        answer = send_test_prompt(test, session.session_id, "Is 391 a prime number?\nAnswer briefly.")
        @test answer.stop_reason == "end_turn"
        updates = test.client.updates
        @test first(updates) isa ACP.SessionInfoUpdate
        @test first(updates).title == "Is 391 a prime number?"
        commands = only(update for update in updates if update isa ACP.AvailableCommandsUpdate)
        @test [command.name for command in commands.available_commands] == ["compact", "init", "review"]
        @test startswith(collect_text(updates, ACP.AgentThoughtChunk), "The user is asking me to determine")
        @test collect_text(updates, ACP.AgentMessageChunk) == "No.\n\nFactors: 1, 17, 23, 391\n\n391 = 17 × 23"
        @test all(update.message_id !== nothing for update in updates if update isa ACP.AgentMessageChunk)
        usage = only(update for update in updates if update isa ACP.UsageUpdate)
        @test usage.size == 200000
        @test usage.used > 0
        @test usage.cost.currency == "USD"
        # The message on the input of claude.
        message = only(fake_message for fake_message in only(fakes).received if fake_message["type"] == "user")
        @test message["message"] == Dict{String,Any}("role" => "user", "content" => Any[Dict{String,Any}(
            "type" => "text", "text" => "Is 391 a prime number?\nAnswer briefly.")])
        close_test_agent(test)
    end

    @testset "a tool call, its result, and a denied call" begin
        test = open_test_agent(make_test_settings([read_recorded("tool-call.jsonl"),
                                                   read_recorded("tool-call-denied.jsonl")]))
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Touch a file.")
        call = only(update for update in test.client.updates if update isa ACP.ToolCall)
        @test (call.name, call.kind, call.status) == ("Bash", "execute", "pending")
        @test call.title == "Create a file named made-by-probe.txt"
        @test call.raw_input["command"] == "touch made-by-probe.txt"
        result = only(update for update in test.client.updates if update isa ACP.ToolCallUpdate)
        @test result.tool_call_id == call.tool_call_id
        @test result.status == "completed"
        @test only(result.content).content.text == "(Bash completed with no output)"
        empty!(test.client.updates)
        send_test_prompt(test, session.session_id, "Touch it again.")
        denied = only(update for update in test.client.updates if update isa ACP.ToolCallUpdate)
        @test denied.status == "failed"
        @test only(denied.content).content.text == "The person said no."
        close_test_agent(test)
    end

    @testset "the task tools make the plan" begin
        test = open_test_agent(make_test_settings([read_recorded("tasks.jsonl")]))
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Plan it.")
        plans = [update for update in test.client.updates if update isa ACP.Plan]
        @test length(plans) == 5
        @test [(entry.content, entry.status) for entry in last(plans).entries] ==
              [("Create the hello-world script file", "in_progress"), ("Add comments to the script", "completed"),
               ("Test the script runs without errors", "pending")]
        close_test_agent(test)
    end

    @testset "a cancel interrupts claude, and the session goes on in the same process" begin
        fakes = FakeClaude[]
        session_id = Ref("")
        client = TestClient(on_update = (client, update) -> begin
            update isa ACP.AgentMessageChunk && count(u -> u isa ACP.AgentMessageChunk, client.updates) == 1 &&
                ACP.send_notification!(test_connection[], ACP.CancelNotification(session_id = session_id[]))
        end)
        test_connection = Ref{Any}(nothing)
        test = open_test_agent(make_test_settings([read_recorded("interrupted.jsonl"), make_result_turn("AFTER")]; fakes);
                               client)
        test_connection[] = test.connection
        session = open_test_session(test)
        session_id[] = session.session_id
        @test send_test_prompt(test, session.session_id, "Count to 300.").stop_reason == "cancelled"
        @test any(message -> message["type"] == "control_request" &&
                             message["request"]["subtype"] == "interrupt", only(fakes).received)
        @test send_test_prompt(test, session.session_id, "Reply AFTER.").stop_reason == "end_turn"
        @test length(fakes) == 1
        close_test_agent(test)
    end

    @testset "a change of an option starts claude again with --resume and its flag" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([make_result_turn("one"), make_result_turn("two")]; fakes))
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "One.")
        answer = ACP.send_request!(test.connection, ACP.SetSessionConfigOptionRequestValueId(
            session_id = session.session_id, config_id = "model", value = "haiku"); timeout = 10)
        @test only(option for option in answer.config_options if option.id == "model").current_value == "haiku"
        ACP.send_request!(test.connection, ACP.SetSessionConfigOptionRequestValueId(
            session_id = session.session_id, config_id = "mode", value = "default"); timeout = 10)
        send_test_prompt(test, session.session_id, "Two.")
        @test length(fakes) == 2
        arguments = last(fakes).arguments
        @test arguments[findfirst(==("--resume"), arguments) + 1] == session.session_id
        @test !("--session-id" in arguments)
        @test arguments[findfirst(==("--model"), arguments) + 1] == "haiku"
        @test arguments[findfirst(==("--permission-mode"), arguments) + 1] == "manual"
        @test !("--effort" in arguments)
        wrong = try
            ACP.send_request!(test.connection, ACP.SetSessionConfigOptionRequestValueId(
                session_id = session.session_id, config_id = "model", value = "gpt"); timeout = 10)
        catch exception
            exception
        end
        @test wrong.code == ACP.INVALID_PARAMS
        close_test_agent(test)
    end

    @testset "a turn that fails answers with the message of claude" begin
        test = open_test_agent(make_test_settings([make_result_turn("Not logged in · Please run /login";
                                                                    is_error = true)]))
        session = open_test_session(test)
        failure = try
            send_test_prompt(test, session.session_id, "Hello.")
        catch exception
            exception
        end
        @test failure isa ACP.ProtocolException
        @test failure.message == "Not logged in · Please run /login"
        close_test_agent(test)

        # A turn that failed at its result keeps claude, and its events do not
        # reach the next prompt.
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([vcat(read_recorded("tool-call.jsonl")[1:3],
                                                        make_result_turn("bad"; is_error = true)),
                                                   make_result_turn("good")]; fakes))
        session = open_test_session(test)
        @test_throws ACP.ProtocolException send_test_prompt(test, session.session_id, "One.")
        empty!(test.client.updates)
        @test send_test_prompt(test, session.session_id, "Two.").stop_reason == "end_turn"
        @test isempty(test.client.updates)
        @test length(fakes) == 1
        close_test_agent(test)
    end

    @testset "a resumed session keeps its title: its first prompt gives none" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([make_result_turn("again")]; fakes))
        id = "9c7e1f0a-2b3d-4e5f-8a6b-7c8d9e0f1a2b"
        ACP.send_request!(test.connection, ACP.ResumeSessionRequest(session_id = id, cwd = TEST_FOLDER); timeout = 10)
        @test send_test_prompt(test, id, "Go on.").stop_reason == "end_turn"
        arguments = only(fakes).arguments
        @test arguments[findfirst(==("--resume"), arguments) + 1] == id
        @test !any(update -> update isa ACP.SessionInfoUpdate, test.client.updates)
        close_test_agent(test)
    end

    @testset "a claude that ends in a turn gives an error, and the next prompt starts it again" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([[Dict{String,Any}("type" => "_exit")], make_result_turn("again")];
                                                  fakes))
        session = open_test_session(test)
        failure = try
            send_test_prompt(test, session.session_id, "Hello.")
        catch exception
            exception
        end
        @test failure.code == ACP.INTERNAL_ERROR
        @test send_test_prompt(test, session.session_id, "Again.").stop_reason == "end_turn"
        @test length(fakes) == 2
        @test "--resume" in last(fakes).arguments
        close_test_agent(test)
    end

    @testset "a session needs the sign-in of claude" begin
        test = open_test_agent(AgentSettings(start_claude = make_fake_starter([]), read_sign_in = command -> false))
        failure = try
            open_test_session(test)
        catch exception
            exception
        end
        @test failure.code == ACP.AUTHENTICATION_REQUIRED
        @test occursin("claude auth login", failure.message)
        close_test_agent(test)
    end

    @testset "a prompt takes text, a link to a file, an embedded text and a picture" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([make_result_turn("ok")]; fakes))
        session = open_test_session(test)
        ACP.send_request!(test.connection, ACP.PromptRequest(session_id = session.session_id, prompt = [
            ACP.TextContent(text = "Look at"),
            ACP.ResourceLink(name = "a b.jl", uri = "file:///work/a%20b.jl"),
            ACP.EmbeddedResource(resource = ACP.TextResourceContents(uri = "file:///work/b.jl", text = "x = 1")),
            ACP.ImageContent(data = "AQID", mime_type = "image/png")]);
            timeout = 10)
        message = only(m for m in only(fakes).received if m["type"] == "user")
        content = message["message"]["content"]
        @test [block["text"] for block in content[1:3]] ==
              ["Look at", "@/work/a b.jl", "<context ref=\"file:///work/b.jl\">\nx = 1\n</context>"]
        @test content[4] == Dict{String,Any}("type" => "image", "source" => Dict{String,Any}(
            "type" => "base64", "media_type" => "image/png", "data" => "AQID"))
        image = try
            ACP.send_request!(test.connection, ACP.PromptRequest(session_id = session.session_id,
                prompt = [ACP.ImageContent(data = "AQID", mime_type = "image/bmp")]); timeout = 10)
        catch exception
            exception
        end
        @test image.code == ACP.INVALID_PARAMS
        close_test_agent(test)
    end

    @testset "the permission tool asks the person, and remembers an allow for always" begin
        decisions = Any[]
        on_call = fake -> begin
            push!(decisions, call_permission_tool(fake, "Bash", Dict{String,Any}("command" => "touch a")))
            push!(decisions, call_permission_tool(fake, "Bash", Dict{String,Any}("command" => "touch b")))
            push!(decisions, call_permission_tool(fake, "Bash", Dict{String,Any}("command" => "x"); secret = "wrong"))
        end
        fakes = FakeClaude[]
        client = TestClient(choice = "allow_always")
        test = open_test_agent(make_test_settings([vcat([Dict{String,Any}("type" => "_call")], make_result_turn("ok"))];
                                                  on_call, fakes); client)
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Run it.")
        @test decisions[1] == Dict{String,Any}("behavior" => "allow",
                                               "updatedInput" => Dict{String,Any}("command" => "touch a"))
        @test decisions[2]["behavior"] == "allow"
        @test decisions[3] == 401
        question = only(client.questions)
        @test question.tool_call.title == "touch a"
        @test [option.kind for option in question.options] == ["allow_always", "allow_once", "reject_once"]
        # Outside a prompt nobody can answer, so the call is denied.
        @test call_permission_tool(only(fakes), "Read", Dict{String,Any}("file_path" => "/a"))["behavior"] == "deny"
        close_test_agent(test)
    end

    @testset "the questions of AskUserQuestion go to the editor as a form, and the answers come back" begin
        questions = Any[
            Dict{String,Any}("question" => "Which colour?", "header" => "Colour", "multiSelect" => false,
                             "options" => Any[Dict{String,Any}("label" => "Red", "description" => "warm"),
                                              Dict{String,Any}("label" => "Blue", "description" => "cool")]),
            Dict{String,Any}("question" => "Which parts?", "header" => "Parts", "multiSelect" => true,
                             "options" => Any[Dict{String,Any}("label" => "A", "description" => ""),
                                              Dict{String,Any}("label" => "B", "description" => "")]),
            Dict{String,Any}("question" => "Which size?", "header" => "Size", "multiSelect" => false,
                             "options" => Any[Dict{String,Any}("label" => "S", "description" => ""),
                                              Dict{String,Any}("label" => "M", "description" => "")])]
        input = Dict{String,Any}("questions" => questions)
        forms = ACP.ClientCapabilities(elicitation = ACP.ElicitationCapabilities(form = ACP.ElicitationFormCapabilities()))
        decisions = Any[]
        on_call = fake -> push!(decisions, call_permission_tool(fake, "AskUserQuestion", input))
        fakes = FakeClaude[]
        client = TestClient(form_content = Dict("question_1" => "Red", "question_2" => ["A", "B"],
                                                "question_3" => "S", "question_3_other" => "extra large"))
        test = open_test_agent(make_test_settings([vcat([Dict{String,Any}("type" => "_call")], make_result_turn("ok"))];
                                                  on_call, fakes); client, client_capabilities = forms)
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Ask me.")
        @test only(decisions) == Dict{String,Any}("behavior" => "allow", "updatedInput" => Dict{String,Any}(
            "questions" => questions,
            "answers" => Dict{String,Any}("Which colour?" => "Red", "Which parts?" => "A, B",
                                          "Which size?" => "extra large")))
        # No permission question: the form is the question.
        @test isempty(client.questions)
        schema = ACP.get_json(only(client.forms))["requestedSchema"]
        @test sort(collect(keys(schema["properties"]))) ==
              ["question_1", "question_1_other", "question_2", "question_2_other", "question_3", "question_3_other"]
        colour = schema["properties"]["question_1"]
        @test (colour["type"], colour["title"], colour["description"]) == ("string", "Colour", "Which colour?")
        @test [(option["const"], option["description"]) for option in colour["oneOf"]] == [("Red", "warm"), ("Blue", "cool")]
        @test schema["properties"]["question_2"]["type"] == "array"
        @test !("--disallowedTools=AskUserQuestion" in only(fakes).arguments)
        close_test_agent(test)

        # A decline is a deny, with a message for Claude.
        decisions = Any[]
        test = open_test_agent(make_test_settings([vcat([Dict{String,Any}("type" => "_call")], make_result_turn("ok"))];
                                                  on_call); client = TestClient(), client_capabilities = forms)
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Ask me.")
        @test only(decisions) == Dict{String,Any}("behavior" => "deny", "message" => "The person declined to answer.")
        close_test_agent(test)

        # An editor that can not show a form: claude starts without the tool.
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([make_result_turn("ok")]; fakes))
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Hello.")
        @test "--disallowedTools=AskUserQuestion" in only(fakes).arguments
        close_test_agent(test)
    end

    @testset "a message while the turn runs goes to claude, and the prompt ends after the turn that takes it" begin
        fakes = FakeClaude[]
        steered = Any[]
        session_id = Ref("")
        steer(text) = ACP.send_request!(test_connection[], "_session/steering",
            ACP.get_json(ACP.PromptRequest(session_id = session_id[], prompt = [ACP.TextContent(text = text)]));
            timeout = 10)
        test_connection = Ref{Any}(nothing)
        on_call = fake -> push!(steered, steer("Also this."))
        turns = [vcat(make_text_events("Working."), [Dict{String,Any}("type" => "_call")], make_result_turn("first")),
                 vcat(make_text_events("Also done."), make_result_turn("second"))]
        test = open_test_agent(make_test_settings(turns; on_call, fakes))
        test_connection[] = test.connection
        session = open_test_session(test)
        session_id[] = session.session_id
        @test send_test_prompt(test, session.session_id, "Work.").stop_reason == "end_turn"
        @test only(steered) == Dict{String,Any}("outcome" => "injected")
        # The prompt went on through the turn that took the message.
        @test collect_text(test.client.updates, ACP.AgentMessageChunk) == "Working.Also done."
        fake = only(fakes)
        @test "--replay-user-messages" in fake.arguments
        @test [message["message"]["content"][1]["text"] for message in fake.received
               if get(message, "type", nothing) == "user"] == ["Work.", "Also this."]
        # No prompt runs now, so a message can not go in.
        @test steer("Late.") == Dict{String,Any}("outcome" => "failed")
        close_test_agent(test)
    end

    @testset "a folder that does not exist, and a claude that can not start" begin
        test = open_test_agent(make_test_settings([]))
        missing_folder = try
            open_test_session(test; cwd = joinpath(TEST_FOLDER, "no-such-folder"))
        catch exception
            exception
        end
        @test missing_folder.code == ACP.INVALID_PARAMS
        close_test_agent(test)
        test = open_test_agent(AgentSettings(claude_command = ["claude-code-acp-no-such-program"],
                                             read_sign_in = command -> true))
        failure = try
            open_test_session(test)
        catch exception
            exception
        end
        @test failure.code == ACP.INTERNAL_ERROR
        @test occursin("can not start", failure.message)
        @test !occursin("Bearer", failure.message)
        @test !occursin("--mcp-config", failure.message)
        close_test_agent(test)
    end

    @testset "a close cancels the prompt that runs" begin
        fakes = FakeClaude[]
        session_id = Ref("")
        test_connection = Ref{Any}(nothing)
        client = TestClient(on_update = (client, update) -> begin
            update isa ACP.AgentMessageChunk && count(u -> u isa ACP.AgentMessageChunk, client.updates) == 1 &&
                @async ACP.send_request!(test_connection[], ACP.CloseSessionRequest(session_id = session_id[]); timeout = 10)
        end)
        test = open_test_agent(make_test_settings([read_recorded("interrupted.jsonl")]; fakes); client)
        test_connection[] = test.connection
        session = open_test_session(test)
        session_id[] = session.session_id
        @test send_test_prompt(test, session.session_id, "Count to 300.").stop_reason == "cancelled"
        @test any(message -> message["type"] == "control_request", only(fakes).received)
        closed = try
            send_test_prompt(test, session.session_id, "Again.")
        catch exception
            exception
        end
        @test closed.code == ACP.INVALID_PARAMS
        close_test_agent(test)
    end

    @testset "a cancel during a start of claude ends the prompt before claude gets it" begin
        gate = Channel{Bool}(1)
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([make_result_turn("one"), make_result_turn("two")]; fakes, gate))
        put!(gate, true)
        session = open_test_session(test)
        ACP.send_request!(test.connection, ACP.SetSessionConfigOptionRequestValueId(
            session_id = session.session_id, config_id = "model", value = "haiku"); timeout = 10)
        prompt = @async send_test_prompt(test, session.session_id, "One.")
        # The prompt waits in the start of the new claude; the cancel comes then.
        @test timedwait(() -> lock(() -> test.agent.sessions[session.session_id].is_prompting,
                                   test.agent.sessions[session.session_id].lock), 10.0) === :ok
        ACP.send_notification!(test.connection, ACP.CancelNotification(session_id = session.session_id))
        sleep(0.2)
        put!(gate, true)
        @test fetch(prompt).stop_reason == "cancelled"
        @test !any(message -> message["type"] == "user", last(fakes).received)
        put!(gate, true)
        @test send_test_prompt(test, session.session_id, "Two.").stop_reason == "end_turn"
        close_test_agent(test)
    end

    @testset "initialize advertises the background tasks" begin
        test = open_test_agent(make_test_settings([]))
        answer = ACP.send_request!(test.connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION);
                                   timeout = 10)
        @test ACP.get_json(answer)["_meta"]["backgroundTasks"] == Dict{String,Any}("supported" => true)
        close_test_agent(test)
    end

    @testset "a subagent is a child session: its prompt, its messages, its progress, its end, and its stop" begin
        recorded = read_recorded("subagent.jsonl")
        first_result = findfirst(event -> event["type"] == "result", recorded)
        released = Channel{Bool}(1)
        fakes = FakeClaude[]
        # The fake waits after the first result, until the test lets it go on.
        turns = [vcat(recorded[1:first_result], [Dict{String,Any}("type" => "_call")], recorded[first_result + 1:end]),
                 make_result_turn("next")]
        test = open_test_agent(make_test_settings(turns; fakes, on_call = fake -> take!(released));
                               client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        @test send_test_prompt(test, session.session_id, "Start a subagent.").stop_reason == "end_turn"
        task_id = "af50c6aab42df01d9"
        updates = test.client.session_updates
        announce = only(update for update in updates if last(update) isa ACP.SubagentUpdate)
        @test first(announce) == session.session_id
        announce = last(announce)
        @test (announce.session_id, announce.title, announce.description) ==
              (task_id, "List and count files in current directory", "general-purpose")
        @test announce.state isa ACP.RunningStateUpdate
        @test announce.capabilities.cancel !== nothing
        prompt = last(only(update for update in updates if first(update) == task_id))
        @test prompt isa ACP.UserMessageChunk
        @test startswith(prompt.content.text, "Use Glob to list all files in the current working directory")
        # A cancel of the child session stops the subagent.
        ACP.send_notification!(test.connection, ACP.CancelNotification(session_id = task_id))
        @test wait_until(() -> any(message -> message["type"] == "control_request", only(fakes).received))
        @test only(message for message in only(fakes).received if message["type"] == "control_request")["request"] ==
              Dict{String,Any}("subtype" => "stop_task", "task_id" => task_id)
        # The subagent works and ends after the result, and claude starts a
        # turn by itself: it all reaches the client, with no prompt.
        put!(released, true)
        @test wait_until(() -> count_usage(test.client) == 2)
        child = [last(update) for update in updates if first(update) == task_id]
        message = only(update for update in child if update isa ACP.AgentMessageChunk)
        @test startswith(message.content.text, "I found **3 files** in the directory `/work`")
        @test message.message_id == "msg_011Cg3emRzJTKvFPvkYyW3vt"
        @test only(update for update in child if update isa ACP.ToolCall).name == "Glob"
        @test only(update for update in child if update isa ACP.ToolCallUpdate).status == "completed"
        states = [last(update) for update in updates if last(update) isa ACP.SubagentUpdate]
        @test all(update.session_id == task_id for update in states)
        @test [typeof(update.state) for update in states] ==
              [ACP.RunningStateUpdate, ACP.RunningStateUpdate, ACP.IdleStateUpdate, Nothing]
        @test states[2].meta["claudeCode"] == Dict("usage" => Dict("totalTokens" => 21399, "toolUses" => 1,
                                                                   "durationMs" => 1857), "lastToolName" => "Glob")
        @test states[3].state.stop_reason == "end_turn"
        @test startswith(states[4].meta["claudeCode"]["summary"], "I found **3 files**")
        @test states[4].meta["claudeCode"]["usage"]["totalTokens"] == 22368
        main = [last(update) for update in updates if first(update) == session.session_id]
        @test collect_text(main, ACP.AgentMessageChunk) == collect_stream_text(recorded)
        # The session keeps nothing of the subagent that ended, and no tool call
        # after a result.
        translation = test.agent.sessions[session.session_id].translation
        @test isempty(translation.subagents) && isempty(translation.subagent_ids)
        @test isempty(translation.state.tool_calls)
        # The next prompt gets only its own turn.
        empty!(test.client.updates)
        @test send_test_prompt(test, session.session_id, "Next.").stop_reason == "end_turn"
        @test isempty(test.client.updates)
        close_test_agent(test)
    end

    @testset "a background task: its notifications, and its stop" begin
        recorded = read_recorded("background-task.jsonl")
        second_start = findfirst(event -> get(event, "subtype", nothing) == "task_started" &&
                                          event["task_id"] == "b1le9w8sz", recorded)
        session_id = Ref("")
        test_connection = Ref{Any}(nothing)
        answers = Any[]
        client = TestClient()
        # The stop comes when the client knows the task.
        on_call = fake -> begin
            wait_until(() -> any(notification -> last(notification)["taskId"] == "b1le9w8sz", client.notifications))
            push!(answers, ACP.send_request!(test_connection[], "_session/stop_background_task",
                Dict{String,Any}("sessionId" => session_id[], "taskId" => "b1le9w8sz"); timeout = 10))
        end
        fakes = FakeClaude[]
        turns = [vcat(recorded[1:second_start], [Dict{String,Any}("type" => "_call")], recorded[second_start + 1:end])]
        test = open_test_agent(make_test_settings(turns; on_call, fakes); client,
                               client_capabilities = make_all_capabilities())
        test_connection[] = test.connection
        session = open_test_session(test)
        session_id[] = session.session_id
        @test send_test_prompt(test, session.session_id, "Run two commands.").stop_reason == "end_turn"
        @test only(answers) == Dict{String,Any}()
        @test only(message for message in only(fakes).received if message["type"] == "control_request")["request"] ==
              Dict{String,Any}("subtype" => "stop_task", "task_id" => "b1le9w8sz")
        @test wait_until(() -> count_usage(client) == 2)
        @test all(first(notification) == "_session/background_task" for notification in client.notifications)
        find_params(task_id) = [last(notification) for notification in client.notifications
                                if last(notification)["taskId"] == task_id]
        # The first notification of a task holds its whole state, and a later
        # one only what changed: the end, and then the summary and the output.
        @test [get(params, "status", nothing) for params in find_params("byowkisnu")] == ["running", "completed", nothing]
        @test [get(params, "status", nothing) for params in find_params("b1le9w8sz")] == ["running", "stopped", nothing]
        started, ended, notified = find_params("byowkisnu")
        @test started["canStop"] === true && started["startTime"] isa Integer
        @test !haskey(started, "endTime") && !haskey(started, "outputUri")
        @test sort(collect(keys(ended))) == ["canStop", "endTime", "sessionId", "status", "taskId"]
        @test sort(collect(keys(notified))) == ["outputUri", "sessionId", "summary", "taskId"]
        @test merge(started, ended, notified) == Dict{String,Any}(
            "sessionId" => session.session_id, "taskId" => "byowkisnu", "kind" => "local_bash",
            "title" => "Run sleep 5 with echo in background", "status" => "completed",
            "toolCallId" => "toolu_01KPkTMkdnkzNeqWEm6zu2ZV",
            "outputUri" => "file:///tmp/claude/work/e1f9a64c-4281-455d-8c50-2ffaa12eb468/tasks/byowkisnu.output",
            "summary" => "Background command \"Run sleep 5 with echo in background\" completed (exit code 0)",
            "startTime" => started["startTime"], "endTime" => 1792050400573, "canStop" => false)
        # A task that does not run can not be stopped.
        failure = try
            ACP.send_request!(test.connection, "_session/stop_background_task",
                              Dict{String,Any}("sessionId" => session.session_id, "taskId" => "byowkisnu"); timeout = 10)
        catch exception
            exception
        end
        @test failure isa ACP.ProtocolException && failure.code == ACP.INVALID_PARAMS
        @test isempty(test.agent.sessions[session.session_id].translation.background_tasks)
        close_test_agent(test)
    end

    @testset "a stop that claude refuses answers its error" begin
        task_start = first(event for event in read_recorded("background-task.jsonl")
                           if get(event, "subtype", nothing) == "task_started")
        session_id = Ref("")
        test_connection = Ref{Any}(nothing)
        answers = Any[]
        client = TestClient()
        on_call = fake -> begin
            wait_until(() -> !isempty(client.notifications))
            push!(answers, try
                ACP.send_request!(test_connection[], "_session/stop_background_task",
                    Dict{String,Any}("sessionId" => session_id[], "taskId" => task_start["task_id"]); timeout = 20)
            catch exception
                exception
            end)
        end
        turns = [vcat([task_start, Dict{String,Any}("type" => "_call")], make_result_turn("one"))]
        test = open_test_agent(make_test_settings(turns; on_call, stop_error = "No task to stop."); client,
                               client_capabilities = make_all_capabilities())
        test_connection[] = test.connection
        session = open_test_session(test)
        session_id[] = session.session_id
        send_test_prompt(test, session.session_id, "Run it.")
        @test only(answers) isa ACP.ProtocolException
        @test only(answers).message == "No task to stop."
        close_test_agent(test)
    end

    @testset "an error result of a turn that claude started by itself does not end the next prompt" begin
        released = Channel{Bool}(1)
        decisions = Any[]
        calls = Ref(0)
        on_call = fake -> begin
            calls[] += 1
            calls[] == 1 ? take!(released) :
                push!(decisions, call_permission_tool(fake, "Bash", Dict{String,Any}("command" => "ls")))
        end
        fakes = FakeClaude[]
        turns = [vcat(make_text_events("One."), make_result_turn("one"), [Dict{String,Any}("type" => "_call")],
                      make_text_events("Self."), make_result_turn("self"; is_error = true)),
                 vcat([Dict{String,Any}("type" => "_call")], make_text_events("Two."), make_result_turn("two"))]
        test = open_test_agent(make_test_settings(turns; on_call, fakes))
        session = open_test_session(test)
        @test send_test_prompt(test, session.session_id, "One.").stop_reason == "end_turn"
        # The second prompt goes to claude while claude runs a turn of its own,
        # which then fails.
        prompt = @async send_test_prompt(test, session.session_id, "Two.")
        @test wait_until(() -> count(message -> message["type"] == "user", only(fakes).received) == 2)
        put!(released, true)
        @test fetch(prompt).stop_reason == "end_turn"
        @test only(decisions)["behavior"] == "allow"
        @test collect_text(test.client.updates, ACP.AgentMessageChunk) == "One.Self.Two."
        @test length(fakes) == 1
        close_test_agent(test)
    end

    @testset "a prompt that fails at its result while a background task runs keeps claude and the task" begin
        task_start = first(event for event in read_recorded("background-task.jsonl")
                           if get(event, "subtype", nothing) == "task_started")
        fakes = FakeClaude[]
        client = TestClient()
        turns = [vcat([task_start], make_result_turn("API Error: 500"; is_error = true)), make_result_turn("two")]
        test = open_test_agent(make_test_settings(turns; fakes); client, client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        @test_throws ACP.ProtocolException send_test_prompt(test, session.session_id, "One.")
        @test send_test_prompt(test, session.session_id, "Two.").stop_reason == "end_turn"
        @test length(fakes) == 1
        @test [last(notification)["status"] for notification in client.notifications] == ["running"]
        @test test.agent.sessions[session.session_id].translation.background_tasks[task_start["task_id"]].status ==
              "running"
        close_test_agent(test)
    end

    @testset "the plan steps go as items with the blockers in _meta, and the plan mode as Markdown" begin
        test = open_test_agent(make_test_settings([read_recorded("plan-steps.jsonl")]);
                               client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Plan it.")
        plans = [update for update in test.client.updates if update isa ACP.PlanUpdate]
        @test length(plans) == 6
        @test !any(update -> update isa ACP.Plan, test.client.updates)
        entries = last(plans).plan.entries
        @test [(entry.content, entry.status) for entry in entries] ==
              [("Write a.txt with echo", "completed"), ("Write b.txt with echo", "pending"), ("Report both", "pending")]
        @test entries[3].meta == Dict("claudeCode" => Dict("taskId" => "3", "description" => "Report both a.txt and b.txt",
                                                           "blockedBy" => ["2"]))
        close_test_agent(test)

        # The plan of the plan mode is only in the question for ExitPlanMode.
        recorded = read_recorded("plan-mode.jsonl")
        request = only(event for event in recorded if event["type"] == "control_request")["request"]
        decisions = Any[]
        on_call = fake -> push!(decisions, call_permission_tool(fake, "ExitPlanMode", request["input"];
                                                                id = request["tool_use_id"]))
        turn = Dict{String,Any}[event["type"] == "control_request" ? Dict{String,Any}("type" => "_call") : event
                                for event in recorded if event["type"] != "control_response"]
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([turn]; on_call, fakes); client = TestClient(choice = "reject"),
                               client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Plan a README.")
        @test only(decisions)["behavior"] == "deny"
        markdown = only(update for update in test.client.updates if update isa ACP.PlanUpdate).plan
        @test markdown isa ACP.PlanMarkdown
        @test (markdown.plan_id, markdown.content) == ("plan-mode", request["input"]["plan"])
        # A question that no prompt can answer sends no plan.
        @test call_permission_tool(only(fakes), "ExitPlanMode", Dict{String,Any}("plan" => "Other."))["behavior"] ==
              "deny"
        @test count(update -> update isa ACP.PlanUpdate, test.client.updates) == 1
        close_test_agent(test)

        # The plan of a subagent goes to its child session.
        subagent_start = only(event for event in read_recorded("subagent.jsonl")
                              if get(event, "subtype", nothing) == "task_started")
        exit_call = Dict{String,Any}("type" => "assistant", "parent_tool_use_id" => subagent_start["tool_use_id"],
            "message" => Dict{String,Any}("id" => "m1", "content" => Any[Dict{String,Any}(
                "type" => "tool_use", "id" => "toolu_exit", "name" => "ExitPlanMode", "input" => Dict{String,Any}())]))
        client = TestClient(choice = "reject")
        on_call = fake -> begin
            wait_until(() -> any(update -> last(update) isa ACP.ToolCall, client.session_updates))
            call_permission_tool(fake, "ExitPlanMode", Dict{String,Any}("plan" => "# Child plan"); id = "toolu_exit")
        end
        test = open_test_agent(make_test_settings([vcat([subagent_start, exit_call, Dict{String,Any}("type" => "_call")],
                                                        make_result_turn("ok"))]; on_call);
                               client, client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        send_test_prompt(test, session.session_id, "Plan in a subagent.")
        plan = only(update for update in client.session_updates if last(update) isa ACP.PlanUpdate)
        @test first(plan) == subagent_start["task_id"]
        @test last(plan).plan.content == "# Child plan"
        close_test_agent(test)
    end

    @testset "a client with no capability beyond version 1 gets the updates of version 1 only" begin
        for name in ("subagent.jsonl", "background-task.jsonl", "plan-steps.jsonl", "plan-mode.jsonl")
            recorded = read_recorded(name)
            test = open_test_agent(make_test_settings([recorded]; process_id = 2^30))
            session = open_test_session(test)
            send_test_prompt(test, session.session_id, "Go.")
            @test wait_until(() -> count_usage(test.client) == count(event -> event["type"] == "result", recorded))
            @test all(first(update) == session.session_id for update in test.client.session_updates)
            @test all(update -> update isa VERSION_1_UPDATES, test.client.updates)
            @test isempty(test.client.notifications)
            @test !any(update -> update isa ACP.SessionInfoUpdate && update.meta !== nothing, test.client.updates)
            @test collect_text(test.client.updates, ACP.AgentMessageChunk) == collect_stream_text(recorded)
            @test count(update -> update isa ACP.Plan, test.client.updates) == (name == "plan-steps.jsonl" ? 6 : 0)
            close_test_agent(test)
        end
    end

    @testset "the end of claude ends the subagents and the background tasks that still run" begin
        subagent_start = only(event for event in read_recorded("subagent.jsonl")
                              if get(event, "subtype", nothing) == "task_started")
        task_start = first(event for event in read_recorded("background-task.jsonl")
                           if get(event, "subtype", nothing) == "task_started")
        work = [subagent_start, task_start]
        turns = [vcat(work, make_result_turn("one")), vcat(work, [Dict{String,Any}("type" => "_exit")])]
        client = TestClient()
        test = open_test_agent(make_test_settings(turns); client, client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        @test send_test_prompt(test, session.session_id, "Start work.").stop_reason == "end_turn"
        # A restart for a new option stops the work of the claude before; the
        # end of the new claude by itself fails its work.
        ACP.send_request!(test.connection, ACP.SetSessionConfigOptionRequestValueId(
            session_id = session.session_id, config_id = "model", value = "haiku"); timeout = 10)
        failure = try
            send_test_prompt(test, session.session_id, "Again.")
        catch exception
            exception
        end
        @test failure isa ACP.ProtocolException && failure.code == ACP.INTERNAL_ERROR
        states = [last(update).state for update in client.session_updates if last(update) isa ACP.SubagentUpdate]
        @test [typeof(state) for state in states] ==
              [ACP.RunningStateUpdate, ACP.IdleStateUpdate, ACP.RunningStateUpdate, ACP.IdleStateUpdate]
        @test [states[2].stop_reason, states[4].stop_reason] == ["cancelled", "cancelled"]
        tasks = [last(notification) for notification in client.notifications]
        @test [(params["taskId"], params["status"], params["canStop"]) for params in tasks] ==
              [("byowkisnu", "running", true), ("byowkisnu", "stopped", false),
               ("byowkisnu", "running", true), ("byowkisnu", "failed", false)]
        @test tasks[2]["endTime"] isa Integer && tasks[4]["endTime"] isa Integer
        close_test_agent(test)
    end

    @testset "the process id of claude goes to the client once for each process" begin
        test = open_test_agent(make_test_settings([make_result_turn("one"), make_result_turn("two"),
                                                   make_result_turn("three")]; process_id = 2^30);
                               client_capabilities = make_all_capabilities())
        session = open_test_session(test)
        @test isempty(test.client.updates)
        process_ids() = [update.meta["processId"] for update in test.client.updates
                         if update isa ACP.SessionInfoUpdate && update.meta !== nothing]
        send_test_prompt(test, session.session_id, "One.")
        @test process_ids() == [2^30]
        send_test_prompt(test, session.session_id, "Two.")
        @test process_ids() == [2^30]
        ACP.send_request!(test.connection, ACP.SetSessionConfigOptionRequestValueId(
            session_id = session.session_id, config_id = "model", value = "haiku"); timeout = 10)
        send_test_prompt(test, session.session_id, "Three.")
        @test process_ids() == [2^30, 2^30]
        close_test_agent(test)
    end

    @testset "a call after a cancel is denied without a question" begin
        test = open_test_agent(make_test_settings([]))
        session = open_test_session(test)
        agent_session = test.agent.sessions[session.session_id]
        lock(agent_session.lock) do
            agent_session.is_prompting = true
            agent_session.is_cancelled = true
        end
        decision = ClaudeCodeACP.decide_permission!(test.agent, agent_session, "Bash",
                                                    Dict{String,Any}("command" => "ls"), "t")
        @test decision["behavior"] == "deny"
        @test isempty(test.client.questions)
        close_test_agent(test)
    end

    @testset "a cancel withdraws a question that waits, and the call is denied" begin
        decisions = Any[]
        session_id = Ref("")
        test_connection = Ref{Any}(nothing)
        on_call = fake -> begin
            canceller = @async (sleep(0.2); ACP.send_notification!(test_connection[],
                                                                   ACP.CancelNotification(session_id = session_id[])))
            push!(decisions, call_permission_tool(fake, "Bash", Dict{String,Any}("command" => "touch c")))
            wait(canceller)
        end
        interrupted = Dict{String,Any}[Dict{String,Any}("type" => "_call"), Dict{String,Any}("type" => "_wait_for_interrupt"),
                                       Dict{String,Any}("type" => "result", "subtype" => "error_during_execution",
                                                        "terminal_reason" => "aborted_tools", "is_error" => true)]
        init = only(event for event in read_recorded("interrupted.jsonl") if get(event, "subtype", nothing) == "init")
        test = open_test_agent(make_test_settings([vcat([init], interrupted)]; on_call); client = TestClient(choice = nothing))
        test_connection[] = test.connection
        session = open_test_session(test)
        session_id[] = session.session_id
        @test send_test_prompt(test, session.session_id, "Run it.").stop_reason == "cancelled"
        @test only(decisions)["behavior"] == "deny"
        close_test_agent(test)
    end
end
