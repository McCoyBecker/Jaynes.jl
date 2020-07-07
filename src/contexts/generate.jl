mutable struct GenerateContext{T <: Trace, K <: ConstrainedSelection} <: ExecutionContext
    tr::T
    select::K
    visited::Visitor
    GenerateContext(tr::T, select::K) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, select, Visitor())
end
Generate(select::ConstrainedSelection) = GenerateContext(Trace(), select)
Generate(tr::Trace, select::ConstrainedSelection) = GenerateContext(tr, select)

# ------------ Choice sites ------------ #

@inline function (ctx::GenerateContext)(call::typeof(rand), 
                                        addr::T, 
                                        d::Distribution{K}) where {T <: Address, K}
    if has_query(ctx.select, addr)
        s = get_query(ctx.select, addr)
        score = logpdf(d, s)
        set_choice!(ctx.tr, addr, ChoiceSite(score, s))
        ctx.tr.score += score
        visit!(ctx.visited, addr)
    else
        s = rand(d)
        set_choice!(ctx.tr, addr, ChoiceSite(logpdf(d, s), s))
        visit!(ctx.visited, addr)
    end
    return s
end

# ------------ Call sites ------------ #

@inline function (ctx::GenerateContext)(c::typeof(rand),
                                        addr::T,
                                        call::Function,
                                        args...) where T <: Address
    cg_ctx = GenerateContext(Trace(), get_sub(ctx.select, addr))
    ret = cg_ctx(call, args...)
    set_call!(ctx.tr, addr, BlackBoxCallSite(cg_ctx.tr, call, args, ret))
    set_sub!(ctx.visited, addr, cg_ctx.visited)
    return ret
end

@inline function (ctx::GenerateContext)(c::typeof(foldr), 
                                        fn::typeof(rand), 
                                        addr::Address, 
                                        call::Function, 
                                        len::Int, 
                                        args...)
    ug_ctx = Generate(Trace(), get_sub(ctx.select, addr => 1))
    ret = ug_ctx(call, args...)
    v_ret = Vector{typeof(ret)}(undef, len)
    v_tr = Vector{HierarchicalTrace}(undef, len)
    v_ret[1] = ret
    v_tr[1] = ug_ctx.tr
    for i in 2:len
        ug_ctx.select = get_sub(ctx.select, addr => i)
        ug_ctx.tr = Trace()
        ret = ug_ctx(call, v_ret[i-1]...)
        v_ret[i] = ret
        v_tr[i] = ug_ctx.tr
    end
    sc = sum(map(v_tr) do tr
                 score(tr)
             end)
    set_call!(ctx.tr, addr, VectorizedCallSite{typeof(foldr)}(v_tr, sc, call, args, v_ret))
    return v_ret
end

@inline function (ctx::GenerateContext)(c::typeof(map), 
                                        fn::typeof(rand), 
                                        addr::Address, 
                                        call::Function, 
                                        args::Vector)
    ug_ctx = Generate(Trace(), get_sub(ctx.select, addr => 1))
    ret = ug_ctx(call, args[1]...)
    len = length(args)
    v_ret = Vector{typeof(ret)}(undef, len)
    v_tr = Vector{HierarchicalTrace}(undef, len)
    v_ret[1] = ret
    v_tr[1] = ug_ctx.tr
    for i in 2:len
        ug_ctx.select = get_sub(ctx.select, addr => i)
        ug_ctx.tr = Trace()
        ret = ug_ctx(call, args[i]...)
        v_ret[i] = ret
        v_tr[i] = ug_ctx.tr
    end
    sc = sum(map(v_tr) do tr
                 score(tr)
             end)
    set_call!(ctx.tr, addr, VectorizedCallSite{typeof(map)}(v_tr, sc, call, args, v_ret))
    return v_ret
end

# Convenience.
function generate(sel::L, fn::Function, args...) where L <: ConstrainedSelection
    ctx = Generate(sel)
    ret = ctx(fn, args...)
    return BlackBoxCallSite(ctx.tr, fn, args, ret), ctx.tr.score
end

function generate(sel::L, fn::typeof(foldr), r::typeof(rand), addr::Symbol, call::Function, args...) where L <: ConstrainedSelection
    ctx = Generate(sel)
    ctx(fn, r, addr, args...)
    return ctx.tr.chm[addr], ctx.tr.chm[addr].score
end

function generate(sel::L, fn::typeof(foldr), call::Function, len::Int, args...) where L <: ConstrainedSelection
    anon_sel = ConstrainedHierarchicalSelection()
    addr = gensym()
    push!(anon_sel, addr, sel)
    ctx = Generate(anon_sel)
    ctx(fn, rand, addr, call, len, args...)
    return ctx.tr.chm[addr], ctx.tr.chm[addr].score
end

function generate(sel::L, fn::typeof(map), r::typeof(rand), addr::Symbol, call::Function, args::Vector) where L <: ConstrainedSelection
    ctx = Generate(sel)
    ctx(fn, r, addr, call, args)
    return ctx.tr.chm[addr], ctx.tr.chm[addr].score
end

function generate(sel::L, fn::typeof(map), call::Function, args::Vector) where L <: ConstrainedSelection
    anon_sel = ConstrainedHierarchicalSelection()
    addr = gensym()
    push!(anon_sel, addr, sel)
    ctx = Generate(anon_sel)
    ctx(fn, rand, addr, call, args)
    return ctx.tr.chm[addr], ctx.tr.chm[addr].score
end

function generate(fn, args...)
    return generate(ConstrainedHierarchicalSelection(), fn, args...)
end
