module Examples

blacklist = ["runexamples.jl", "trace_translation.jl", "support_checks.jl", "combinator_trace_types.jl", "hierarchical_trace_types.jl", "variational_inference.jl"]

for p in readdir("examples"; join=false)
    !(p in blacklist) && include(p)
end

end # module
