module Regen

include("../src/Walkman.jl")
using .Walkman
using Distributions

function bar(x)
    z = rand(:z, Normal, (x, 1.0))
    return rand(:bar, Normal, (z + x, 1.0))
end

ctx, tr, score = trace(bar, (5.0, ))
display(tr)
regen_ctx = Regenerate(tr, Address[:bar])
ctx, tr, score = trace(regen_ctx, tr, (6.0,))
display(tr)

end # module
