macro load_gen_fmi()
    @info "Loading foreign model interface to \u001b[3m\u001b[34;1mGen.jl\u001b[0m\n\n          \u001b[34;1mhttps://www.gen.dev/\n\nThis interface currently supports Gen's full feature set.\n\n\u001b[1mGen and Jaynes share exports - please qualify usage of the following context APIs:\n\u001b[0m\n \u001b[31msimulate   \u001b[0m-> \u001b[32mJaynes.simulate\n \u001b[31mgenerate   \u001b[0m-> \u001b[32mJaynes.generate\n \u001b[31mupdate     \u001b[0m-> \u001b[32mJaynes.update\n \u001b[31mregenerate \u001b[0m-> \u001b[32mJaynes.regenerate\n "
    expr = quote
        import Jaynes: has_top, get_top, has_sub, get_sub, get_score, collect!
        using Gen

        # ------------ Call site ------------ #

        struct GenerativeFunctionCallSite{T <: Gen.Trace, M <: GenerativeFunction, A, K} <: Jaynes.CallSite
            trace::T
            score::Float64
            model::M
            args::A
            ret::K
        end

        get_score(gfcs::GenerativeFunctionCallSite) = gfcs.score
        haskey(cs::GenerativeFunctionCallSite, addr) = has_value(get_choices(cs.trace), addr)
        getindex(cs::GenerativeFunctionCallSite, addrs...) = getindex(get_choices(cs.trace), addrs...)
        get_ret(cs::GenerativeFunctionCallSite) = get_retval(cs.trace)

        # ------------ Pretty printing ------------ #

        function collect!(par::P, addrs::Vector{Any}, chd::Dict{Any, Any}, tr::T, meta) where {P <: Tuple, T <: Gen.Trace}
            choices = get_choices(tr)
            for (k, v) in get_values_shallow(choices)
                push!(addrs, (par..., k))
                chd[(par..., k)] = v
                meta[(par..., k)] = "(Gen)"
            end
            for (k, v) in get_submaps_shallow(choices)
                collect!((par..., k), addrs, chd, v.trace, meta)
            end
        end

        function collect!(addrs::Vector{Any}, chd::Dict{Any, Any}, tr::T, meta) where T <: Gen.Trace
            choices = get_choices(tr)
            for (k, v) in get_values_shallow(choices)
                push!(addrs, (k, ))
                chd[(k, )] = v
            end
            for (k, v) in get_submaps_shallow(choices)
                collect!((k, ), addrs, chd, v.trace, meta)
            end
        end

        # ------------ Contexts ------------ #

        function (ctx::Jaynes.SimulateContext)(c::typeof(gen_fmi),
                                               addr::Jaynes.Address,
                                               gen_fn::M,
                                               args...) where M <: GenerativeFunction
            Jaynes.visit!(ctx, addr)
            tr = Gen.simulate(gen_fn, args)
            Jaynes.add_call!(ctx, addr, GenerativeFunctionCallSite(tr, Gen.get_score(tr), gen_fn, args, Gen.get_retval(tr)))
            return Gen.get_retval(tr)
        end

        function (ctx::Jaynes.ProposeContext)(c::typeof(gen_fmi),
                                              addr::Jaynes.Address,
                                              gen_fn::M,
                                              args...) where M <: GenerativeFunction
            Jaynes.visit!(ctx, addr)
            tr, w, ret = Gen.propose(gen_fn, args, choice_map)
            Jaynes.add_call!(ctx, addr, GenerativeFunctionCallSite(tr, Gen.get_score(tr), gen_fn, args, Gen.get_retval(tr)))
            Jaynes.increment!(ctx, w)
            return ret
        end

        function (ctx::Jaynes.GenerateContext)(c::typeof(gen_fmi),
                                               addr::Jaynes.Address,
                                               gen_fn::M,
                                               args...) where M <: GenerativeFunction
            Jaynes.visit!(ctx, addr)
            choice_map = Jaynes.get_top(ctx.select, addr)
            tr, w = Gen.generate(gen_fn, args, choice_map)
            Jaynes.add_call!(ctx, addr, GenerativeFunctionCallSite(tr, Gen.get_score(tr), gen_fn, args, Gen.get_retval(tr)))
            Jaynes.increment!(ctx, w)
            return Gen.get_retval(tr)
        end

        function (ctx::Jaynes.UpdateContext)(c::typeof(gen_fmi),
                                             addr::Jaynes.Address,
                                             gen_fn::M,
                                             args...) where M <: GenerativeFunction
            Jaynes.visit!(ctx, addr)
            choice_map = Jaynes.get_top(ctx.select, addr)
            prev = Jaynes.get_prev(ctx, addr)
            new, w, rd, d = Gen.update(prev.trace, args, (), choice_map)
            Jaynes.add_call!(ctx, addr, GenerativeFunctionCallSite(new, Gen.get_score(new), gen_fn, args, Gen.get_retval(new)))
            Jaynes.increment!(ctx, w)
            return Gen.get_retval(new)
        end

        function (ctx::Jaynes.RegenerateContext)(c::typeof(gen_fmi),
                                                 addr::Jaynes.Address,
                                                 gen_fn::M,
                                                 args...) where M <: GenerativeFunction
            Jaynes.visit!(ctx, addr)
            choice_map = Jaynes.get_top(ctx.select, addr)
            prev = Jaynes.get_prev(ctx, addr)
            new, w, rd, d = Gen.regenerate(prev.trace, args, (), choice_map)
            Jaynes.add_call!(ctx, addr, GenerativeFunctionCallSite(new, Gen.get_score(new), gen_fn, args, Gen.get_retval(new)))
            Jaynes.increment!(ctx, w)
            return Gen.ret_retval(new)
        end

        function (ctx::Jaynes.ScoreContext)(c::typeof(gen_fmi),
                                            addr::Jaynes.Address,
                                            gen_fn::M,
                                            args...) where M <: GenerativeFunction
            Jaynes.visit!(ctx, addr)
            choice_map = Jaynes.get_top(ctx.select, addr)
            w, ret = Gen.assess(gen_fn, args, choice_map)
            Jaynes.add_call!(ctx, addr, GenerativeFunctionCallSite(new, Gen.get_score(new), gen_fn, args, Gen.get_retval(new)))
            Jaynes.increment!(ctx, w)
            return ret
        end
    end

    expr = MacroTools.prewalk(unblock ∘ rmlines, expr)
    esc(expr)
end
