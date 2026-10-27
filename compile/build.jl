# Build the program `claude-code-acp` as a native binary, with PackageCompiler:
#
#     julia compile/build.jl
#
# The bundle goes to `build/claude-code-acp/` in this repository, and the
# executable to `build/claude-code-acp/bin/claude-code-acp`. The binary holds the
# agent of this checkout, and it runs on processors of the kind of this machine.

isempty(ARGS) || (println(stderr, "usage: julia compile/build.jl"); exit(1))

# Julia loads the libstdc++ of the machine when it is newer than its own, and the
# build copies the library that Julia loaded. A copy of the machine's library can
# need a newer glibc than a user has, so the build runs again in a Julia that
# loads its own. A binary still loads a newer one of its user's machine when
# there is one.
if get(ENV, "JULIA_PROBE_LIBSTDCXX", "") != "0"
    command = `$(Base.julia_cmd()) --project=$(@__DIR__) $(@__FILE__)`
    exit(run(ignorestatus(addenv(command, "JULIA_PROBE_LIBSTDCXX" => "0"))).exitcode)
end

using Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()
using PackageCompiler

const APP = joinpath(@__DIR__, "ClaudeCodeAcpApp")
const OUTPUT = joinpath(dirname(@__DIR__), "build", "claude-code-acp")

# Each build resolves the app again, so that its manifest holds what the
# `Project.toml` of this checkout says now.
Pkg.activate(APP)
Pkg.resolve()
Pkg.activate(@__DIR__)
create_app(APP, OUTPUT;
           executables = ["claude-code-acp" => "julia_main"],
           force = true,
           incremental = true,
           include_lazy_artifacts = true,
           cpu_target = "native",
           sysimage_build_args = `-O3 -g1`)

executable = joinpath(OUTPUT, "bin", "claude-code-acp")
run(`$executable --help`)
println("\n", executable)
