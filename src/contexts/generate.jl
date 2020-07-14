mutable struct GenerateContext{T <: Trace, K <: ConstrainedSelection} <: ExecutionContext
    tr::T
    select::K
    weight::Float64
    score::Float64
    visited::Visitor
    params::LearnableParameters
    GenerateContext(tr::T, select::K) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, select, 0.0, 0.0, Visitor(), LearnableParameters())
    GenerateContext(tr::T, select::K, params) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, select, 0.0, 0.0, Visitor(), params)
end
Generate(select::ConstrainedSelection) = GenerateContext(Trace(), select)
Generate(select::ConstrainedSelection, params) = GenerateContext(Trace(), select, params)
Generate(tr::Trace, select::ConstrainedSelection) = GenerateContext(tr, select)

# ------------ Choice sites ------------ #

@inline function (ctx::GenerateContext)(call::typeof(rand), 
                                        addr::T, 
                                        d::Distribution{K}) where {T <: Address, K}
    visit!(ctx, addr)
    if has_query(ctx.select, addr)
        s = get_query(ctx.select, addr)
        score = logpdf(d, s)
        add_choice!(ctx.tr, addr, ChoiceSite(score, s))
        increment_weight!(ctx, score)
        increment_score!(ctx, score)
    else
        s = rand(d)
        add_choice!(ctx.tr, addr, ChoiceSite(logpdf(d, s), s))
        increment_score!(ctx, score)
    end
    return s
end

# ------------ Learnable ------------ #

@inline function (ctx::GenerateContext)(fn::typeof(learnable), addr::Address, p::T) where T
    visit!(ctx, addr)
    ret = p
    if has_param(ctx.params, addr)
        ret = get_param(ctx.params, addr)
    end
    ctx.tr.params[addr] = ParameterSite(ret)
    return ret
end

# ------------ Black box call sites ------------ #

@inline function (ctx::GenerateContext)(c::typeof(rand),
                                        addr::T,
                                        call::Function,
                                        args...) where T <: Address
    visit!(ctx, addr)
    ss = get_subselection(ctx, addr)
    ret, cl, w = generate(ss, call, args...)
    add_call!(ctx.tr, addr, cl)
    increment_weight!(ctx, w)
    increment_score!(ctx, get_score(cl))
    return ret
end

# ------------ Vectorized call sites ------------ #

@inline function (ctx::GenerateContext)(c::typeof(markov), 
                                        addr::Address, 
                                        call::Function, 
                                        len::Int, 
                                        args...)
    visit!(ctx, addr => 1)
    ss = get_subselection(ctx, addr => 1)
    ret, cl, w = generate(ss, call, args...)
    v_ret = Vector{typeof(ret)}(undef, len)
    v_cl = Vector{typeof(cl)}(undef, len)
    v_ret[1] = ret
    v_cl[1] = cl
    increment_weight!(ctx, w)
    for i in 2:len
        visit!(ctx, addr => i)
        ss = get_subselection(ctx, addr => i)
        ret, cl, w = generate(ss, call, v_ret[i-1]...)
        v_ret[i] = ret
        v_cl[i] = cl
        increment_weight!(ctx, w)
    end
    sc = sum(map(v_cl) do cl
                 get_score(cl)
             end)
    increment_score!(ctx, sc)
    add_call!(ctx.tr, addr, VectorizedSite{typeof(markov)}(v_cl, sc, call, args, v_ret))
    return v_ret
end

@inline function (ctx::GenerateContext)(c::typeof(plate), 
                                        addr::Address, 
                                        call::Function, 
                                        args::Vector)
    visit!(ctx, addr => 1)
    len = length(args)
    ss = get_subselection(ctx, addr => 1)
    ret, cl, w = generate(ss, call, args[1]...)
    v_ret = Vector{typeof(ret)}(undef, len)
    v_cl = Vector{typeof(cl)}(undef, len)
    v_ret[1] = ret
    v_cl[1] = cl
    increment_weight!(ctx, w)
    for i in 2:len
        visit!(ctx, addr => i)
        ss = get_subselection(ctx, addr => i)
        ret, cl, w = generate(ss, call, args[i]...)
        v_ret[i] = ret
        v_cl[i] = cl
        increment_weight!(ctx, w)
    end
    sc = sum(map(v_cl) do cl
                 get_score(cl)
             end)
    increment_score!(ctx, sc)
    add_call!(ctx.tr, addr, VectorizedSite{typeof(markov)}(v_cl, sc, call, args, v_ret))
    return v_ret
end

# ------------ Convenience ------------ #

function generate(sel::L, fn::Function, args...; params = LearnableParameters()) where L <: ConstrainedSelection
    ctx = Generate(sel, params)
    ret = ctx(fn, args...)
    return ret, BlackBoxCallSite(ctx.tr, ctx.score, fn, args, ret), ctx.weight
end

function generate(sel::L, fn::typeof(markov), addr::Symbol, call::Function, args...) where L <: ConstrainedSelection
    ctx = Generate(sel)
    ret = ctx(fn, r, addr, args...)
    return ret, ctx.tr.chm[addr], ctx.weight
end

function generate(sel::L, fn::typeof(plate), addr::Symbol, call::Function, args::Vector) where L <: ConstrainedSelection
    ctx = Generate(sel)
    ret = ctx(fn, r, addr, call, args)
    return ret, ctx.tr.chm[addr], ctx.weight
end

function generate(fn, args...)
    return generate(ConstrainedHierarchicalSelection(), fn, args...)
end

# ------------ Documentation ------------ #

@doc(
"""
```julia
mutable struct GenerateContext{T <: Trace, K <: ConstrainedSelection} <: ExecutionContext
     tr::T
     select::K
     weight::Float64
     visited::Visitor
     params::LearnableParameters
end
```
`GenerateContext` is used to generate traces, as well as record and accumulate likelihood weights given observations at addressed randomness.

Inner constructors:
```julia
GenerateContext(tr::T, select::K) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, select, 0.0, Visitor(), LearnableParameters())
GenerateContext(tr::T, select::K, params) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, select, 0.0, Visitor(), params)
```
Outer constructors:
```julia
Generate(select::ConstrainedSelection) = GenerateContext(Trace(), select)
Generate(select::ConstrainedSelection, params) = GenerateContext(Trace(), select, params)
Generate(tr::Trace, select::ConstrainedSelection) = GenerateContext(tr, select)
```
""", GenerateContext)
