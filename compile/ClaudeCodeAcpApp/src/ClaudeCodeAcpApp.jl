"""
    ClaudeCodeAcpApp

The program `claude-code-acp` as PackageCompiler compiles it. `compile/build.jl`
makes a native binary of this package, and the binary calls [`julia_main`](@ref).
"""
module ClaudeCodeAcpApp

using PrecompileTools
import ClaudeCodeACP

# `SIGTERM` ends the program at once and in silence, as it ends most programs.
# The signal listener of the Julia runtime takes `SIGTERM` as a fatal signal and
# prints the stack of every thread. Linux gives a signal sent to the process to
# its main thread first when that thread does not block it, and the default
# action of `SIGTERM` then ends the process with exit status 143.
function _end_on_terminate!()::Nothing
    Sys.islinux() || return nothing
    signals = zeros(UInt8, 128)             # a `sigset_t`
    ccall(:sigemptyset, Cint, (Ptr{UInt8},), signals)
    # 15 is SIGTERM, C_NULL is SIG_DFL, and 1 is SIG_UNBLOCK.
    ccall(:sigaddset, Cint, (Ptr{UInt8}, Cint), signals, 15)
    ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 15, C_NULL)
    ccall(:pthread_sigmask, Cint, (Cint, Ptr{UInt8}, Ptr{Cvoid}), 1, signals, C_NULL)
    nothing
end

"""
    julia_main() -> Cint

The entry of the binary. The log goes to the standard error from the level warn
up, and the exit code is the one of `ClaudeCodeACP.main`.
"""
function julia_main()::Cint
    Base.CoreLogging.global_logger(Base.CoreLogging.ConsoleLogger(stderr, Base.CoreLogging.Warn))
    _end_on_terminate!()
    Cint(ClaudeCodeACP.main(ARGS))
end

# The agent serves a client in the process through `initialize`, on two streams,
# so the first answer of the binary needs no compilation. It starts no `claude`.
@compile_workload begin
    ACP = ClaudeCodeACP.ACP
    to_agent, to_client = Base.BufferStream(), Base.BufferStream()
    agent = @async ClaudeCodeACP.serve_agent(; input = to_agent, output = to_client)
    connection = ACP.open_connection(nothing, to_client, to_agent)
    ACP.send_request!(connection, ACP.InitializeRequest(protocol_version = ACP.PROTOCOL_VERSION);
                      timeout = 60)
    ACP.close_connection!(connection)
    wait(agent)
end

end # module ClaudeCodeAcpApp
