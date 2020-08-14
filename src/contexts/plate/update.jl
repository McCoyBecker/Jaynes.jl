# ------------ Utilities ------------ #

function trace_retained(vcs::VectorizedCallSite, 
                        s::K, 
                        ks, 
                        o_len::Int, 
                        n_len::Int, 
                        args::Vector) where K <: ConstrainedSelection
    w_adj = -sum(map(vcs.trace.subrecords[n_len + 1 : end]) do cl
                     get_score(cl)
                 end)
    new = vcs.trace.subrecords[1 : n_len]
    new_ret = typeof(vcs.ret)(undef, n_len)
    for i in 1 : n_len
        if i in ks
            ss = get_sub(s, i)
            prev_cl = get_sub(vcs, i)
            ret, u_cl, u_w, rd, ds = update(ss, prev_cl, UndefinedChange(), args[i]...)
            new_ret[i] = ret
            new[i] = u_cl
            w_adj += u_w
        else
            new_ret[i] = get_ret(get_sub(vcs, i))
        end
    end
    return w_adj, new, new_ret
end

function trace_new(vcs::VectorizedCallSite, 
                   s::K, 
                   ks, 
                   o_len::Int, 
                   n_len::Int, 
                   args::Vector) where K <: ConstrainedSelection
    w_adj = 0.0
    new_ret = typeof(vcs.ret)(undef, n_len)
    new = vcs.trace.subrecords
    for i in o_len + 1 : n_len
        ss = get_sub(s, i)
        ret, cl, w = generate(ss, call, args[i]...)
        new_ret[i] = ret
        new[i] = cl
        w_adj += w
    end
    for i in 1 : o_len
        i in ks && begin
            ss = get_sub(s, i)
            prev_cl = get_sub(vcs, i)
            ret, u_cl, u_w, rd, d = update(ss, prev_cl, UndefinedChange(), args[i]...)
            new_ret[i] = ret
            new[i] = u_cl
            w_adj += u_w
            continue
        end
    end
    return w_adj, new, new_ret
end

# ------------ Call sites ------------ #

@inline function (ctx::UpdateContext{C, T})(c::typeof(plate), 
                                            addr::Address, 
                                            call::Function, 
                                            args::Vector) where {C <: HierarchicalCallSite, T <: HierarchicalTrace}
    visit!(ctx, addr)
    vcs = get_prev(ctx, addr)
    n_len, o_len = length(args), length(vcs.args)
    s = get_subselection(ctx, addr)
    _, ks = keyset(s, n_len)
    if n_len <= o_len
        w_adj, new, new_ret = trace_retained(vcs, s, ks, o_len, n_len, args)
    else
        w_adj, new, new_ret = trace_new(vcs, s, ks, o_len, n_len, args)
    end
    add_call!(ctx, addr, VectorizedCallSite{typeof(plate)}(VectorizedTrace(new), get_score(vcs) + w_adj, call, n_len, args, new_ret))
    increment!(ctx, w_adj)

    return new_ret
end

@inline function (ctx::UpdateContext{C, T})(c::typeof(plate), 
                                            call::Function, 
                                            args::Vector) where {C <: VectorizedCallSite, T <: VectorizedTrace}
    vcs = ctx.prev
    n_len, o_len = length(args), length(vcs.args)
    s = ctx.select
    ps = ctx.fixed
    _, ks = keyset(s, n_len)
    if n_len <= o_len
        w_adj, new, new_ret = trace_retained(vcs, s, ps, ks, o_len, n_len, args)
    else
        w_adj, new, new_ret = trace_new(vcs, s, ps, ks, o_len, n_len, args)
    end

    for n in new
        add_call!(ctx, n)
    end
    increment!(ctx, w_adj)

    return new_ret
end

# ------------ Convenience ------------ #

# TODO: disallowed for now.
#function update(sel::L, vcs::VectorizedCallSite{typeof(plate)}, argdiffs::D, new_args...) where {L <: AddressMap, D <: Diff}
#    addr = gensym()
#    v_sel = selection(addr => sel)
#    ctx = UpdateContext(vcs, v_sel, argdiffs)
#    ret = ctx(plate, addr, vcs.fn, new_args...)
#    return ret, VectorizedCallSite{typeof(plate)}(ctx.tr, ctx.score, vcs.fn, vcs.args, ret), ctx.weight, UndefinedChange(), ctx.discard
#end

function update(sel::L, vcs::VectorizedCallSite{typeof(plate)}) where L <: AddressMap
    argdiffs = NoChange()
    ctx = UpdateContext(vcs, sel, argdiffs)
    ret = ctx(plate, vcs.fn, vcs.args)
    return ret, VectorizedCallSite{typeof(plate)}(ctx.tr, ctx.score, vcs.fn, vcs.args, ret), ctx.weight, UndefinedChange(), ctx.discard
end

function update(sel::L, ps::P, vcs::VectorizedCallSite{typeof(plate)}) where {L <: AddressMap, P <: AddressMap}
    argdiffs = NoChange()
    ctx = UpdateContext(vcs, sel, ps, argdiffs)
    ret = ctx(plate, vcs.fn, vcs.args)
    return ret, VectorizedCallSite{typeof(plate)}(ctx.tr, ctx.score, vcs.fn, vcs.args, ret), ctx.weight, UndefinedChange(), ctx.discard
end
