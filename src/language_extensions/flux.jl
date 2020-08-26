macro load_flux_fmi()
    @info "Loading differentiable compatibility to \u001b[3m\u001b[34;1mFlux.jl\u001b[0m\n\n          \u001b[34;1mhttps://github.com/FluxML/Flux.jl\n "

    expr = quote

        using Flux
        using Flux: Chain, Dense, update!

        (ctx::Jaynes.SimulateContext)(fn::typeof(deep), model, args...) = model(args...)
        (ctx::Jaynes.GenerateContext)(fn::typeof(deep), model, args...) = model(args...)
        (ctx::Jaynes.UpdateContext)(fn::typeof(deep), model, args...) = model(args...)

        (ctx::Jaynes.RegenerateContext)(fn::typeof(deep), model, args...) = model(args...)
        (ctx::Jaynes.ProposeContext)(fn::typeof(deep), model, args...) = model(args...)
        (ctx::Jaynes.ScoreContext)(fn::typeof(deep), model, args...) = model(args...)

        mutable struct FluxNetworkTrainContext{T <: Jaynes.CallSite, 
                                               S <: Jaynes.AddressMap, 
                                               P <: Jaynes.AddressMap} <: Jaynes.BackpropagationContext
            call::T
            weight::Float64
            scaler::Float64
            fixed::S
            initial_params::P
            opt
        end

        function DeepBackpropagate(fixed, params, call::T, opt, scaler) where T <: Jaynes.CallSite
            FluxNetworkTrainContext(call,
                                    0.0,
                                    scaler,
                                    fixed,
                                    params,
                                    opt)
        end

        apply_model!(ctx, model, args...) = model(args...)

        Zygote.@adjoint function apply_model!(ctx, model, args...)
            ret = model(args...)
            fn = params_grad -> begin
                _, back = Zygote.pullback((m, x) -> m(x...), model, args)
                gs, arg_grads = back(params_grad)
                ps, re = Flux.destructure(model)
                scaled_grads = ctx.scaler * Flux.destructure(gs)[1]
                update!(ctx.opt, ps, scaled_grads)
                new = Flux.params(re(ps))
                Flux.loadparams!(model, new)
                (nothing, nothing, arg_grads...)
            end
            return ret, fn
        end

        simulate_deep_pullback(fixed, params, cl::T, args) where T <: Jaynes.CallSite = get_ret(cl)

        Zygote.@adjoint function simulate_deep_pullback(fixed, params, cl::T, args) where T <: Jaynes.CallSite
            ret = simulate_deep_pullback(fixed, params, cl, args)
            fn = ret_grad -> begin
                arg_grads = accumulate_deep_gradients!(fixed, params, cl, ret_grad)
                (nothing, nothing, nothing, arg_grads)
            end
            ret, fn
        end

        function accumulate_deep_gradients!(fx, ps, cl, ret_grad, opt, scaler)
            fn = args -> begin
                ctx = DeepBackpropagate(fx, ps, cl, opt, scaler)
                ret = ctx(cl.fn, args...)
                (ctx.weight, ret)
            end
            _, back = Zygote.pullback(fn, cl.args)
            arg_grads = back((1.0, ret_grad))[1]
            arg_grads
        end

        function (ctx::FluxNetworkTrainContext)(fn::typeof(Jaynes.deep), 
                                                model,
                                                args...) where A <: Jaynes.Address
            ret = apply_model!(ctx, model, args...)
            ret
        end

        @inline function (ctx::FluxNetworkTrainContext)(call::typeof(rand), 
                                                        addr::T, 
                                                        d::Distribution{K}) where {T <: Jaynes.Address, K}
            if haskey(ctx.fixed, addr)
                s = getindex(ctx.fixed, addr)
            else
                s = Jaynes.get_value(Jaynes.get_sub(ctx.call, addr))
            end
            Jaynes.increment!(ctx, logpdf(d, s))
            return s
        end

        @inline function (ctx::FluxNetworkTrainContext)(c::typeof(rand),
                                                        addr::T,
                                                        call::Function,
                                                        args...) where T <: Jaynes.Address
            cl = get_sub(ctx.call, addr)
            fx = get_sub(ctx.fixed, addr)
            ps = get_sub(ctx.initial_params, addr)
            ret = simulate_deep_pullback(fx, ps, cl, args)
            return ret
        end

        function deep_train!(ps::P, cl::C, ret_grad; opt = ADAM(), scaler = 1.0) where {P <: Jaynes.AddressMap, C <: Jaynes.CallSite}
            arg_grads = accumulate_deep_gradients!(Jaynes.Empty(), ps, cl, ret_grad, opt, scaler)
            return arg_grads
        end

        function deep_train!(cl::C, ret_grad; opt = ADAM(), scaler = 1.0) where {P <: Jaynes.AddressMap, C <: Jaynes.CallSite}
            arg_grads = accumulate_deep_gradients!(Jaynes.Empty(), Jaynes.Empty(), cl, ret_grad, opt, scaler)
            return arg_grads
        end

        function one_shot_neural_gradient_estimator_step!(tg::K,
                                                          ps::P,
                                                          v_mod::Function,
                                                          v_args::Tuple,
                                                          mod::Function,
                                                          args::Tuple;
                                                          opt = ADAM(),
                                                          scale = 1.0) where {K <: Jaynes.AddressMap, P <: Jaynes.AddressMap}
            _, cl = simulate(ps, v_mod, v_args...)
            obs, _ = merge(cl, tg)
            _, mlw = score(obs, ps, mod, args...)
            lw = mlw - get_score(cl)
            as = deep_train!(ps, cl, 1.0; opt = opt, scaler = lw * scale)
            return lw, cl
        end

        const osnges! = one_shot_neural_gradient_estimator_step!

        function neural_variational_inference(tg::K,
                                              ps::P,
                                              v_mod::Function,
                                              v_args::Tuple,
                                              mod::Function,
                                              args::Tuple;
                                              opt = ADAM(0.05, (0.9, 0.8)),
                                              iters = 1000) where {K <: Jaynes.AddressMap, P <: Jaynes.AddressMap}
            cls = Vector{Jaynes.CallSite}(undef, iters)
            elbows = Vector{Float64}(undef, iters)
            Threads.@threads for i in 1 : iters
                elbo_est = 0.0
                lw, cl = osnges!(tg, ps, 
                                 v_mod, v_args, 
                                 mod, args; 
                                 opt = opt, scale = 1.0)
                elbo_est += lw
                cls[i] = cl
                elbows[i] = elbo_est
            end
            elbows, cls
        end

        function neural_variational_inference(tg::K,
                                              v_mod::Function,
                                              v_args::Tuple,
                                              mod::Function,
                                              args::Tuple;
                                              opt = ADAM(0.05, (0.9, 0.8)),
                                              iters = 1000) where {K <: Jaynes.AddressMap, P <: Jaynes.AddressMap}
            neural_variational_inference(tg, 
                                         Jaynes.Empty(), 
                                         v_mod, 
                                         v_args, 
                                         mod, 
                                         args; 
                                         opt = opt, 
                                         iters = iters)
        end

        const nvi = neural_variational_inference

        function multi_shot_neural_gradient_estimator_step!(tg::K,
                                                            ps::P,
                                                            v_mod::Function,
                                                            v_args::Tuple,
                                                            mod::Function,
                                                            args::Tuple;
                                                            opt = ADAM(),
                                                            num_samples::Int = 100,
                                                            scale = 1.0) where {K <: Jaynes.AddressMap, P <: Jaynes.AddressMap}
            cs = Vector{Jaynes.CallSite}(undef, num_samples)
            lws = Vector{Float64}(undef, num_samples)
            Threads.@threads for i in 1:num_samples
                _, cs[i] = simulate(ps, v_mod, v_args...)
                obs, _ = merge(cs[i], tg)
                ret, mlw = score(obs, ps, mod, args...)
                lws[i] = mlw - get_score(cs[i])
            end
            ltw = Jaynes.lse(lws)
            L = ltw - log(num_samples)
            nw = exp.(lws .- ltw)
            bs = Jaynes.geometric_base(lws)
            Threads.@threads for i in 1 : num_samples
                ls = L - nw[i] - bs[i]
                deep_train!(ps, cs[i], 1.0; opt = opt, scaler = ls * scale)
            end
            return L, cs, nw
        end

        const msnges! = multi_shot_neural_gradient_estimator_step!

        function neural_geometric_vimco(tg::K,
                                        ps::P,
                                        num_samples::Int,
                                        v_mod::Function,
                                        v_args::Tuple,
                                        mod::Function,
                                        args::Tuple;
                                        opt = ADAM(0.05, (0.9, 0.8)),
                                        iters = 1000) where {K <: Jaynes.AddressMap, P <: Jaynes.AddressMap}
            cls = Vector{Jaynes.CallSite}(undef, iters)
            velbows = Vector{Float64}(undef, iters)
            Threads.@threads for i in 1 : iters
                velbo_est = 0.0
                L, cs, nw = msnges!(tg, ps, 
                                    v_mod, v_args, 
                                    mod, args; 
                                    opt = opt, num_samples = num_samples, scale = 1.0)
                velbo_est += L
                println(sum(nw))
                cls[i] = cs[rand(Categorical(nw))]
                velbows[i] = velbo_est
            end
            velbows, cls
        end

        function neural_geometric_vimco(tg::K,
                                        num_samples::Int,
                                        v_mod::Function,
                                        v_args::Tuple,
                                        mod::Function,
                                        args::Tuple;
                                        opt = ADAM(0.05, (0.9, 0.8)),
                                        iters = 1000) where {K <: Jaynes.AddressMap, P <: Jaynes.AddressMap}
            neural_geometric_vimco(tg, 
                                   Jaynes.Empty(), 
                                   num_samples, 
                                   v_mod, 
                                   v_args, 
                                   mod, 
                                   args; 
                                   opt = opt, 
                                   iters = iters)
        end

        const nvimco = neural_geometric_vimco
    end

    expr = MacroTools.prewalk(unblock ∘ rmlines, expr)
    esc(expr)
end
