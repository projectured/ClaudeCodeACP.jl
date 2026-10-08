using Test
using ClaudeCodeACP
import ClaudeCodeACP: ACP

include("fake_claude.jl")

@testset "ClaudeCodeACP" begin
    include("translation.jl")
    include("agent.jl")
    Sys.isunix() && include("process.jl")
end
