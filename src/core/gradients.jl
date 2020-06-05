struct SiteGradients{K}
    sample::Float64
    gs::Dict{Address, K}
end

mutable struct UnconstrainedGradientMeta <: Meta
    stack::Vector{Address}
    visited::Vector{Address}
    trainable::Dict{Address, Union{Number, AbstractArray}}
    gradients::Dict{Address, Vector{SiteGradients}}
    tracker::IdDict{Union{Number, AbstractArray}, Address}
    parents::Dict{Address, Vector{Address}}
    tr::Trace
    args::Tuple
    fn::Function
    ret::Any
    UnconstrainedGradientMeta() = new(Address[], 
                                      Address[], 
                                      Dict{Address, Number}(), 
                                      Dict{Address, Tuple}(), 
                                      IdDict{Float64, Address}(), 
                                      Dict{Address, Vector{Address}}(),
                                      Trace())
    UnconstrainedGradientMeta(tr::Trace) = new(Address[], 
                                               Address[], 
                                               Dict{Address, Number}(), 
                                               Dict{Address, Tuple}(), 
                                               IdDict{Float64, Address}(), 
                                               Dict{Address, Vector{Address}}(),
                                               tr)
end
Gradient() = disablehooks(TraceCtx(metadata = UnconstrainedGradientMeta()))
Gradient(pass::Cassette.AbstractPass) = disablehooks(TraceCtx(pass = pass, metadata = UnconstrainedGradientMeta()))

# --------------- OVERDUB -------------------- #

function Cassette.overdub(ctx::TraceCtx{M}, 
                          call::typeof(rand), 
                          addr::T, 
                          dist::Type,
                          args) where {M <: UnconstrainedGradientMeta, 
                                       T <: Address}
    # Check stack.
    !isempty(ctx.metadata.stack) && begin
        push!(ctx.metadata.stack, addr)
        addr = foldr((x, y) -> x => y, ctx.metadata.stack)
        pop!(ctx.metadata.stack)
    end

    # Check for support errors.
    addr in ctx.metadata.visited && error("AddressError: each address within a rand call must be unique. Found duplicate $(addr).")

    # Build dependency graph.
    passed_in = filter(args) do a 
        if a in keys(ctx.metadata.tracker)
            k = ctx.metadata.tracker[a]
            if haskey(ctx.metadata.parents, addr) && !(k in ctx.metadata.parents[addr])
                push!(ctx.metadata.parents[addr], k)
            else
                ctx.metadata.parents[addr] = [k]
            end
            true
        else
            false
        end
    end

    args = map(args) do a
        if haskey(ctx.metadata.tracker, a)
            k = ctx.metadata.tracker[a]
            if haskey(ctx.metadata.trainable, k)
                return ctx.metadata.trainable[k][1]
            else
                a
            end
        else
            a
        end
    end

    passed_in = IdDict{Any, Address}(map(passed_in) do a
                                         k = ctx.metadata.tracker[a]
                                         a => k
                                     end)
    d = dist(args...)

    # Check trace for choice map.
    if haskey(ctx.metadata.tr.chm, addr)
        sample = ctx.metadata.tr.chm[addr].val
    else
        sample = rand(d)
    end
    ctx.metadata.tracker[sample] = addr

    # Gradients
    gs = Flux.gradient((s, a) -> -logpdf(dist(a...), s), sample, args)
    args_arr = Pair{Address, Float64}[]
    map(enumerate(args)) do (i, a)
        haskey(passed_in, a) && begin
            push!(args_arr, passed_in[a] => gs[2][i])
        end
    end

    if !isempty(args_arr)
        grads = SiteGradients(gs[1], Dict(args_arr...))

        # Push grads to parents.
        map(ctx.metadata.parents[addr]) do p
            p in keys(ctx.metadata.trainable) && begin
                if haskey(ctx.metadata.gradients, p)
                    push!(ctx.metadata.gradients[p], grads)

                else
                    ctx.metadata.gradients[p] = [grads]
                end
            end
        end
    end

    push!(ctx.metadata.visited, addr)
    return sample
end

function Cassette.overdub(ctx::TraceCtx{M}, 
                          call::typeof(rand), 
                          addr::T,
                          lit::K) where {M <: UnconstrainedGradientMeta, 
                                         T <: Address,
                                         K <: Union{Number, AbstractArray}}
    # Check stack.
    !isempty(ctx.metadata.stack) && begin
        push!(ctx.metadata.stack, addr)
        addr = foldr((x, y) -> x => y, ctx.metadata.stack)
        pop!(ctx.metadata.stack)
    end

    # Check for support errors.
    addr in ctx.metadata.visited && error("AddressError: each address within a rand call must be unique. Found duplicate $(addr).")

    # Check if value in trainable.
    if haskey(ctx.metadata.trainable, addr)
        ret = ctx.metadata.trainable[addr][1]
    else
        ret = lit
    end

    # Track.
    ctx.metadata.tracker[ret] = addr
    !haskey(ctx.metadata.trainable, addr) && begin
        ctx.metadata.trainable[addr] = [ret]
    end

    push!(ctx.metadata.visited, addr)
    return ret
end

# ------------------ END OVERDUB ------------------- #

import Flux: update!

function update!(opt, ctx::TraceCtx{M}) where M <: UnconstrainedGradientMeta
    for (k, val) in ctx.metadata.trainable
        if haskey(ctx.metadata.gradients, k)
            gs = ctx.metadata.gradients[k]
            map(gs) do g
                ctx.metadata.trainable[k] = update!(opt, val, [g.gs[k]])
            end
        end
    end
    ctx.metadata.gradients = Dict{Address, Union{Number, AbstractArray}}()
    ctx.metadata.visited = Address[]
    ctx.metadata.tracker = IdDict{Union{Number, AbstractArray}, Address}()
end