"""
    ClaudeCodeACP

An agent of the Agent Client Protocol (ACP) that runs Claude Code, the `claude`
program that the person installed and signed in. It is not made by Anthropic.

An editor starts the program `claude-code-acp` and talks ACP to it on its
standard input and output. For each session the agent starts one
`claude -p` process, which streams its work as JSON, and translates that stream
into the updates of the session. Before Claude Code runs a tool that needs the
word of the person, it calls the permission tool of the agent, a small MCP
server on the loopback address, and the agent asks the editor.

The agent uses the sign-in of `claude` and reads no credential.
"""
module ClaudeCodeACP

import AgentClientProtocol as ACP
using HTTP
using JSON
using Sockets
using UUIDs: uuid4
using Random: RandomDevice

export ClaudeCodeAgent, AgentSettings, serve_agent, close_agent!

include("process.jl")
include("translation.jl")
include("permission.jl")
include("agent.jl")
include("program.jl")

end # module ClaudeCodeACP
