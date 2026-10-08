# The agent through ACP, with a client of AgentClientProtocol in this process and
# a fake `claude` that plays recorded turns.

mutable struct TestClient <: ACP.ClientHandler
    updates::Vector{Any}
    questions::Vector{Any}
    choice::Union{Nothing,String}
    on_update::Function
end

TestClient(; choice = "allow", on_update = (client, update) -> nothing) =
    TestClient(Any[], Any[], choice, on_update)

function ACP.receive_notification(client::TestClient, notification::ACP.SessionNotification, connection)
    push!(client.updates, notification.update)
    client.on_update(client, notification.update)
end

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
function open_test_agent(settings::AgentSettings; client = TestClient())
    agent = ClaudeCodeAgent(settings)
    to_agent = Base.BufferStream()
    to_client = Base.BufferStream()
    agent_connection = ACP.open_connection(agent, to_agent, to_client)
    connection = ACP.open_connection(client, to_client, to_agent)
    ACP.send_request!(connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION); timeout = 10)
    (; agent, connection, agent_connection, client)
end

function close_test_agent(test)
    ACP.close_connection!(test.connection)
    close_agent!(test.agent)
end

make_test_settings(turns; kwargs...) =
    AgentSettings(; start_claude = make_fake_starter(turns; kwargs...), check_sign_in = command -> true)

open_test_session(test; mcp_servers = []) =
    ACP.send_request!(test.connection, ACP.NewSessionRequest(cwd = "/work", mcp_servers = mcp_servers); timeout = 10)

send_test_prompt(test, session_id, text) =
    ACP.send_request!(test.connection, ACP.PromptRequest(session_id = session_id,
                                                         prompt = [ACP.TextContent(text = text)]); timeout = 20)

collect_text(updates, type) = join(update.content.text for update in updates if update isa type)

@testset "the agent" begin
    @testset "initialize names the agent and the way to sign in" begin
        agent = ClaudeCodeAgent(AgentSettings(check_sign_in = command -> true))
        to_agent, to_client = Base.BufferStream(), Base.BufferStream()
        ACP.open_connection(agent, to_agent, to_client)
        connection = ACP.open_connection(TestClient(), to_client, to_agent)
        answer = ACP.send_request!(connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION); timeout = 10)
        @test answer.protocol_version == 1
        @test answer.agent_info.name == "claude-code-acp"
        @test answer.agent_capabilities.session_capabilities.close !== nothing
        @test answer.agent_capabilities.session_capabilities.resume !== nothing
        login = only(answer.auth_methods)
        @test login isa ACP.AuthMethodTerminal
        @test login.args == ["--login"]
        ACP.close_connection!(connection)
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
        @test !("--strict-mcp-config" in arguments)
        @test fake.directory == "/work"
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
                                               check_sign_in = command -> true, strict_mcp_config = true))
        open_test_session(strict)
        @test "--strict-mcp-config" in last(fakes).arguments
        close_test_agent(strict)
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
        test = open_test_agent(AgentSettings(start_claude = make_fake_starter([]), check_sign_in = command -> false))
        failure = try
            open_test_session(test)
        catch exception
            exception
        end
        @test failure.code == ACP.AUTHENTICATION_REQUIRED
        @test occursin("claude auth login", failure.message)
        close_test_agent(test)
    end

    @testset "a prompt takes text, a link to a file and an embedded text" begin
        fakes = FakeClaude[]
        test = open_test_agent(make_test_settings([make_result_turn("ok")]; fakes))
        session = open_test_session(test)
        ACP.send_request!(test.connection, ACP.PromptRequest(session_id = session.session_id, prompt = [
            ACP.TextContent(text = "Look at"),
            ACP.ResourceLink(name = "a.jl", uri = "file:///work/a.jl"),
            ACP.EmbeddedResource(resource = ACP.TextResourceContents(uri = "file:///work/b.jl", text = "x = 1"))]);
            timeout = 10)
        message = only(m for m in only(fakes).received if m["type"] == "user")
        @test [block["text"] for block in message["message"]["content"]] ==
              ["Look at", "@/work/a.jl", "<context ref=\"file:///work/b.jl\">\nx = 1\n</context>"]
        image = try
            ACP.send_request!(test.connection, ACP.PromptRequest(session_id = session.session_id,
                prompt = [ACP.ImageContent(data = "", mime_type = "image/png")]); timeout = 10)
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
