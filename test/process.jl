# A `claude` in a real process: a shell script that writes two events, and the
# check of the sign-in by `claude auth status`.

const FAKE_CLAUDE_SCRIPT = raw"""
read -r line
printf '{"type":"system","subtype":"init","capabilities":["interrupt_receipt_v1"],"parent":"%s"}\n' "${CLAUDECODE:-none}"
printf '{"type":"result","subtype":"success","result":"ok"}\n'
cat > /dev/null
"""

# The next event, or an error after ten seconds.
function take_event!(claude)
    timedwait(() -> isready(claude.events), 10.0) === :ok || error("No event came in ten seconds.")
    take!(claude.events)
end

@testset "claude in a process" begin
    @testset "a process starts, answers, keeps no variable of a parent session, and ends" begin
        withenv("CLAUDECODE" => "1") do
            claude = ClaudeCodeACP.open_claude_process(`sh -c $(FAKE_CLAUDE_SCRIPT)`)
            ClaudeCodeACP.send_user_message!(claude, [Dict{String,Any}("type" => "text", "text" => "hi")])
            init = take_event!(claude)
            @test init["parent"] == "none"
            @test take_event!(claude)["result"] == "ok"
            @test claude.capabilities == ["interrupt_receipt_v1"]
            started = time()
            ClaudeCodeACP.close_claude_process!(claude)
            @test time() - started < 4
            @test take_event!(claude)["type"] == "process_exit"
            @test !ClaudeCodeACP.is_claude_running(claude)
        end
    end

    @testset "the sign-in comes from the field loggedIn" begin
        status(text) = ["sh", "-c", "printf '%s' '$(text)'", "claude"]
        @test ClaudeCodeACP.read_claude_sign_in(status("""{"loggedIn": true, "email": "a@b.c"}""")) === true
        @test ClaudeCodeACP.read_claude_sign_in(status("""{"loggedIn": false}""")) === false
        @test ClaudeCodeACP.read_claude_sign_in(status("not json")) === nothing
        @test ClaudeCodeACP.read_claude_sign_in(["claude-code-acp-no-such-program"]) === nothing
    end

    @testset "the flag of the thinking display comes from the refusal of a wrong value" begin
        knows(flag_known) = ["sh", "-c", flag_known ?
            "echo \"error: option '--thinking-display <display>' argument 'x' is invalid.\" >&2; exit 1" :
            "echo 2.1.285; exit 0", "claude"]
        @test ClaudeCodeACP.read_claude_thinking_display(knows(true)) === true
        @test ClaudeCodeACP.read_claude_thinking_display(knows(false)) === false
        @test ClaudeCodeACP.read_claude_thinking_display(["claude-code-acp-no-such-program"]) === false
    end

    @testset "the program prints its usage" begin
        @test redirect_stdout(() -> ClaudeCodeACP.main(["--help"]), devnull) == 0
        @test redirect_stderr(() -> ClaudeCodeACP.main(["--no-such-flag"]), devnull) == 2
    end
end
