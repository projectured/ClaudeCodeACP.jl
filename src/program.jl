# The program: the agent on the standard input and output of its process, as an
# editor starts it.

"""
    serve_agent(; input = stdin, output = stdout, settings = AgentSettings())

Serve one editor on two streams until it closes its stream, and then end each
session. Nothing else may write to `output`: the log goes to the standard
error.
"""
function serve_agent(; input::IO = stdin, output::IO = stdout, settings::AgentSettings = AgentSettings())
    agent = ClaudeCodeAgent(settings)
    connection = ACP.open_connection(agent, input, output)
    try
        wait(connection)
    finally
        close_agent!(agent)
        ACP.close_connection!(connection)
    end
    nothing
end

const USAGE = """
    claude-code-acp [--strict-mcp-config] [--claude=PATH]
    claude-code-acp --login

An agent of the Agent Client Protocol (ACP) that runs Claude Code, the `claude`
program that you installed and signed in. An editor starts it and talks to it on
its standard input and output. It is not made by Anthropic.

  --strict-mcp-config  give Claude Code only the MCP servers of the editor
  --claude=PATH        the program of Claude Code (default: claude)
  --login              run `claude auth login` in this terminal
"""

"""
    main(arguments) -> Int

The program `claude-code-acp`. Answers the exit code.
"""
function main(arguments::AbstractVector{<:AbstractString})
    claude = "claude"
    strict = false
    login = false
    for argument in arguments
        if argument == "--strict-mcp-config"
            strict = true
        elseif startswith(argument, "--claude=")
            claude = argument[10:end]
        elseif argument == "--login"
            login = true
        elseif argument in ("--help", "-h")
            print(USAGE)
            return 0
        else
            print(stderr, "Unknown argument `$(argument)`.\n\n", USAGE)
            return 2
        end
    end
    login && return _run_login(claude)
    serve_agent(; settings = AgentSettings(claude_command = [claude], strict_mcp_config = strict))
    0
end

function _run_login(claude::String)
    process = run(ignorestatus(`$claude auth login`))
    process.exitcode
end

(@main)(arguments) = main(arguments)
