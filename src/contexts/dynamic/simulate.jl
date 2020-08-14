# ------------ Choice sites ------------ #

@inline function (ctx::SimulateContext)(call::typeof(rand), 
                                        addr::T, 
                                        d::Distribution{K}) where {T <: Address, K}
    visit!(ctx.visited, addr)
    s = rand(d)
    add_choice!(ctx, addr, logpdf(d, s), s)
    return s
end

# ------------ Learnable ------------ #

@inline function (ctx::SimulateContext)(fn::typeof(learnable), addr::T) where T <: Address
    visit!(ctx, addr)
    has_top(ctx.params, addr) && return get_top(ctx.params, addr)
    error("Parameter not provided at address $addr.")
end

# ------------ Black box call sites ------------ #

@inline function (ctx::SimulateContext)(c::typeof(rand),
                                        addr::T,
                                        call::Function,
                                        args...) where T <: Address
    visit!(ctx, addr)
    ps = get_subparameters(ctx, addr)
    ret, cl = simulate(ps, call, args...)
    add_call!(ctx, addr, cl)
    return ret
end

# ------------ Convenience ------------ #

function simulate(fn::Function, args...)
    ctx = SimulateContext()
    ret = ctx(fn, args...)
    return ret, DynamicCallSite(ctx.tr, ctx.score, fn, args, ret)
end

function simulate(params::P, fn::Function, args...) where P <: AddressMap
    ctx = SimulateContext(params)
    ret = ctx(fn, args...)
    return ret, DynamicCallSite(ctx.tr, ctx.score, fn, args, ret)
end

function simulate(fn::typeof(rand), d::Distribution{T}) where T
    ctx = SimulateContext()
    addr = gensym()
    ret = ctx(rand, addr, d)
    return ret, get_top(ctx.tr, addr)
end

function simulate(params::P, fn::typeof(rand), d::Distribution{T}) where {P <: AddressMap, T}
    ctx = SimulateContext(params)
    addr = gensym()
    ret = ctx(rand, addr, d)
    return ret, get_top(ctx.tr, addr)
end

