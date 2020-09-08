# ------------ Choice sites ------------ #

@inline function (ctx::RegenerateContext)(call::typeof(rand), 
                                          addr::T, 
                                          d::Distribution{K}) where {T <: Address, K}
    visit!(ctx, addr)
    in_prev_chm = has_value(get_trace(ctx.prev), addr)
    in_sel = haskey(ctx.target, addr)
    
    if in_prev_chm
        prev = get_sub(get_trace(ctx.prev), addr)
    end
    
    if in_sel && in_prev_chm
        ret = rand(d)
        set_sub!(ctx.discard, addr, prev)
    elseif in_prev_chm
        ret = prev.val
    else
        ret = rand(d)
    end

    score = logpdf(d, ret)
    in_prev_chm && increment!(ctx, score - get_score(prev))
    add_choice!(ctx, addr, score, ret)
    return ret
end

# ------------ Learnable ------------ #

@inline function (ctx::RegenerateContext)(fn::typeof(learnable), addr::Address)
    visit!(ctx, addr)
    haskey(ctx.params, addr) && return getindex(ctx.params, addr)
    error("(learnable): parameter not provided at address $addr.")
end

# ------------ Fillable ------------ #

@inline function (ctx::RegenerateContext)(fn::typeof(fillable), addr::Address)
    haskey(ctx.target, addr) && return getindex(ctx.target, addr)
    error("(fillable): parameter not provided at address $addr.")
end

# ------------ Black box call sites ------------ #

@inline function (ctx::RegenerateContext)(c::typeof(rand),
                                          addr::T,
                                          call::Function,
                                          args...) where T <: Address
    visit!(ctx, addr)
    ps = get_sub(ctx.params, addr)
    ss = get_sub(ctx.target, addr)
    if has_sub(get_trace(ctx.prev), addr)
        prev_call = get_prev(ctx, addr)
        ret, cl, w, retdiff, d = regenerate(ss, ps, prev_call, UnknownChange(), args...)
    else
        ret, cl, w = generate(ss, ps, call, args...)
    end
    add_call!(ctx, addr, cl)
    increment!(ctx, w)
    return ret
end

# ------------ Utilities ------------ #

function regenerate_projection_walk(tr::DynamicTrace,
                                    visited::Visitor)
    weight = 0.0
    for (k, v) in shallow_iterator(tr)
        if !(k in visited)
            weight += projection(v, SelectAll())[1]
        end
    end
    weight
end

function regenerate_discard_walk!(d::DynamicDiscard,
                                  visited::Visitor,
                                  prev::DynamicTrace)
    for (k, v) in shallow_iterator(prev)
        if !(k in visited)
            ss = get_sub(visited, k)
            if isempty(ss)
                set_sub!(d, k, v)
            else
                sd = get_sub(d, k)
                sd = isempty(sd) ? DynamicMap{Value}() : sd
                discard_walk!(sd, ss, v)
                set_sub!(d, k, sd)
            end
        end
    end
end

# ------------ Convenience ------------ #

function regenerate(ctx::RegenerateContext, cs::DynamicCallSite, args::Tuple, argdiffs::Tuple)
    ret = ctx(cs.fn, args...)
    adj_w = regenerate_projection_walk(ctx.tr, ctx.visited)
    regenerate_discard_walk!(ctx.discard, ctx.visited, ctx.tr)
    return ret, DynamicCallSite(ctx.tr, ctx.score - adj_w, cs.fn, args, ret), ctx.weight, UnknownChange(), ctx.discard
end

function regenerate(sel::L, cs::DynamicCallSite) where L <: Target
    ctx = Regenerate(sel, Empty(), cs, DynamicTrace(), DynamicDiscard(), NoChange())
    return regenerate(ctx, cs, cs.args, ())
end

function regenerate(sel::L, cs::DynamicCallSite, args::Tuple, argdiffs::Tuple) where L <: Target
    ctx = Regenerate(sel, Empty(), cs, DynamicTrace(), DynamicDiscard(), NoChange())
    return regenerate(ctx, cs, args, argdiffs)
end

function regenerate(sel::L, ps::P, cs::DynamicCallSite) where {L <: Target, P <: AddressMap}
    ctx = Regenerate(sel, ps, cs, DynamicTrace(), DynamicDiscard(), NoChange())
    return regenerate(ctx, cs, cs.args, ())
end

function regenerate(sel::L, ps::P, cs::DynamicCallSite, args::Tuple, argdiffs::Tuple) where {L <: Target, P <: AddressMap}
    ctx = Regenerate(sel, ps, cs, DynamicTrace(), DynamicDiscard(), NoChange())
    return regenerate(ctx, cs, args, argdiffs)
end
