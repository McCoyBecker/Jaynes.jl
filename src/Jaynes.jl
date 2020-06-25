module Jaynes

using Cthulhu

# IRRRR I'm a com-pirate.
using Cassette
using Cassette: recurse, similarcontext, disablehooks, Reflection, canrecurse
import Cassette: overdub, prehook, posthook, Reflection, fallback
using MacroTools
using MacroTools: postwalk
using IRTools
using IRTools: meta, IR, slots!, Variable, typed_meta
import IRTools: meta, IR
using Mjolnir
using Logging
using Dates

using Distributions

# Differentiable goop.
using Flux
using Flux: Params
using Zygote
using DistributionsAD

const Address = Union{Symbol, Pair{Symbol, Int64}}

include("core/static.jl")
include("core/trace.jl")
include("core/selections.jl")
include("core/contexts.jl")
include("core/gradients.jl")
include("core/blackbox.jl")
include("core/language_cores.jl")
include("utils.jl")
include("inference/importance_sampling.jl")
include("inference/particle_filter.jl")
include("inference/inference_compilation.jl")
include("inference/metropolis_hastings.jl")
include("tracing.jl")
include("core/passes.jl")

# Allows debug tracing in packages which use Jaynes.
function derive_debug(mod; path = "jayneslog_$(Time(Dates.now())).txt", type_tracing = false, all_calls = false)
    io = open(path, "w+")
    logger = Logging.SimpleLogger(io)
    Logging.global_logger(logger)
    @assert mod isa Module
    fns = filter(names(mod)) do nm
        try
            Base.eval(mod, nm) isa Function
        catch e
            println("Ignoring call in $e.")
            false
        end
    end
    if type_tracing
        @eval begin
            using Revise
        end
    end

    @info "Jaynes says: deriving debug calls.\n$(map(x -> String(x) * "\n", fns)...)"
    exprs = map(fns) do f
        if type_tracing
            @eval mod begin
                function Jaynes.prehook(::Jaynes.TraceCtx, call::typeof($mod.$f), args...)
                    @info "\n$(stacktrace()[3])\n" call typeof(args)
                    println("Beginning type inference...")
                    Cthulhu.descend(call, typeof(args))
                end
            end
        else
            @eval mod begin
                function Jaynes.prehook(::Jaynes.TraceCtx, call::typeof($mod.$f), args...)
                    @info "\n$(stacktrace()[3])\n" call typeof(args)
                end
            end
        end
    end

    if all_calls
        @eval mod begin
            function Jaynes.prehook(::Jaynes.TraceCtx, call::Function, args...)
                @info "\n$(stacktrace()[3])\n" call typeof(args)
            end
        end
    end
    
    return logger 
end

end # module
