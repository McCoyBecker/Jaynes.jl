import Base: +, setindex!, filter!

# ------------ Parameter store ------------ #

struct ParameterStore
    params::Dict{Address,Any}
    ParameterStore() = new(Dict{Address, Any}())
    ParameterStore(d::Dict{Address, Any}) = new(d)
end
haskey(ps::ParameterStore, addr) = haskey(ps.params, addr)
setindex!(ps::ParameterStore, val, addr) = ps.params[addr] = val

Zygote.@adjoint ParameterStore(params) = ParameterStore(params), store_grad -> (nothing,)

function +(a::ParameterStore, b::ParameterStore)
    params = Dict{Address, Any}()
    for (k, v) in Iterators.flatten((a.params, b.params))
        if !haskey(params, k)
            params[k] = v
        else
            params[k] += v
        end
    end
    ParameterStore(params)
end

# ------------ Backpropagation contexts ------------ #

abstract type BackpropagationContext <: ExecutionContext end

# Learnable parameters
mutable struct ParameterBackpropagateContext{T <: CallSite, S <: ConstrainedSelection} <: BackpropagationContext
    call::T
    weight::Float64
    fixed::S
    initial_params::Parameters
    params::ParameterStore
    param_grads::Gradients
end
ParameterBackpropagate(call::T, init, params) where T <: CallSite = ParameterBackpropagateContext(call, 0.0, selection(), init, params, Gradients())
ParameterBackpropagate(call::T, sel::S, init, params) where {T <: CallSite, S <: ConstrainedSelection} = ParameterBackpropagateContext(call, 0.0, sel, init, params, Gradients())
ParameterBackpropagate(call::T, init, params, param_grads::Gradients) where {T <: CallSite, K <: UnconstrainedSelection} = ParameterBackpropagateContext(call, 0.0, selection(), init, params, param_grads)
ParameterBackpropagate(call::T, sel::S, init, params, param_grads::Gradients) where {T <: CallSite, S <: ConstrainedSelection, K <: UnconstrainedSelection} = ParameterBackpropagateContext(call, 0.0, sel, init, params, param_grads)

# Choice sites
mutable struct ChoiceBackpropagateContext{T <: CallSite, S <: ConstrainedSelection, K <: UnconstrainedSelection} <: BackpropagationContext
    call::T
    weight::Float64
    fixed::S
    initial_params::Parameters
    params::ParameterStore
    choice_grads::Gradients
    select::K
end
ChoiceBackpropagate(call::T, init, params, choice_grads) where {T <: CallSite, K <: UnconstrainedSelection} = ChoiceBackpropagateContext(call, 0.0, selection(), init, params, choice_grads, UnconstrainedAllSelection())
ChoiceBackpropagate(call::T, fixed::S, init, params, choice_grads) where {T <: CallSite, S <: ConstrainedSelection, K <: UnconstrainedSelection} = ChoiceBackpropagateContext(call, 0.0, fixed, init, params, choice_grads, UnconstrainedAllSelection())
ChoiceBackpropagate(call::T, init, params, choice_grads, sel::K) where {T <: CallSite, K <: UnconstrainedSelection} = ChoiceBackpropagateContext(call, 0.0, selection(), init, params, choice_grads, sel)
ChoiceBackpropagate(call::T, fixed::S, init, params, choice_grads, sel::K) where {T <: CallSite, S <: ConstrainedSelection, K <: UnconstrainedSelection} = ChoiceBackpropagateContext(call, 0.0, fixed, init, params, choice_grads, sel)

# ------------ Learnable ------------ #

read_parameter(ctx::K, addr::Address) where K <: BackpropagationContext = read_parameter(ctx, ctx.params, addr)
read_parameter(ctx::K, params::ParameterStore, addr::Address) where K <: BackpropagationContext = get_top(ctx.initial_params, addr)

Zygote.@adjoint function read_parameter(ctx, params, addr)
    ret = read_parameter(ctx, params, addr)
    fn = param_grad -> begin
        state_grad = nothing
        params_grad = ParameterStore(Dict{Address, Any}(addr => param_grad))
        (state_grad, params_grad, nothing)
    end
    return ret, fn
end

# ------------ Call sites ------------ #

# Grads for learnable parameters.
simulate_parameter_pullback(sel, params, param_grads, cl::T, args) where T <: CallSite = cl.ret

Zygote.@adjoint function simulate_parameter_pullback(sel, params, param_grads, cl::HierarchicalCallSite, args)
    ret = simulate_parameter_pullback(sel, params, param_grads, cl, args)
    fn = ret_grad -> begin
        arg_grads = accumulate_parameter_gradients!(sel, params, param_grads, cl, ret_grad)
        (nothing, nothing, nothing, nothing, arg_grads)
    end
    return ret, fn
end

# Utility.
merge(tp1::Tuple{}, tp2::Tuple{}) = tp1
merge(tp1::Tuple{Nothing}, tp2::Tuple{Nothing}) where T = tp1
merge(tp1::NTuple{N, Float64}, tp2::NTuple{N, Float64}) where N = [tp1[i] + tp2[i] for i in 1 : N]
merge(tp1::Array{Float64}, tp2::NTuple{N, Float64}) where N = [tp1[i] + tp2[i] for i in 1 : N]

Zygote.@adjoint function simulate_parameter_pullback(sel, params, param_grads, cl::VectorizedCallSite{typeof(markov)}, args)
    ret = simulate_parameter_pullback(sel, params, param_grads, cl, args)
    fn = ret_grad -> begin
        arg_grads = accumulate_parameter_gradients!(sel, params, param_grads, get_sub(cl, cl.len), ret_grad)
        for i in (cl.len - 1) : -1 : 1
            arg_grads = accumulate_parameter_gradients!(sel, params, param_grads, get_sub(cl, i), arg_grads)
        end
        (nothing, nothing, nothing, nothing, arg_grads)
    end
    return ret, fn
end

Zygote.@adjoint function simulate_parameter_pullback(sel, params, param_grads, cl::VectorizedCallSite{typeof(plate)}, args)
    ret = simulate_parameter_pullback(sel, params, param_grads, cl, args)
    fn = ret_grad -> begin
        arg_grads = accumulate_parameter_gradients!(sel, params, param_grads, get_sub(cl, cl.len), ret_grad[1])
        for i in 2 : cl.len
            new = accumulate_parameter_gradients!(sel, params, param_grads, get_sub(cl, i), ret_grad[i])
            arg_grads = merge(arg_grads, new)
        end
        (nothing, nothing, nothing, nothing, arg_grads)
    end
    return ret, fn
end

# Grads for choices with differentiable logpdfs.
simulate_choice_pullback(params, choice_grads, choice_selection, cl::T, args) where T <: CallSite = get_ret(cl)

Zygote.@adjoint function simulate_choice_pullback(params, choice_grads, choice_selection, cl, args)
    ret = simulate_choice_pullback(params, choice_grads, choice_selection, cl, args)
    fn = ret_grad -> begin
        arg_grads, choice_vals, choice_grads = choice_gradients(params, choice_grads, choice_selection, cl, ret_grad)
        (nothing, nothing, nothing, (choice_vals, choice_grads), arg_grads)
    end
    return ret, fn
end

# ------------ Accumulate gradients ------------ #

function accumulate_parameter_gradients!(sel, initial_params, param_grads, cl::HierarchicalCallSite, ret_grad, scaler::Float64 = 1.0)
    fn = (args, params) -> begin
        ctx = ParameterBackpropagate(cl, sel, initial_params, params, param_grads)
        ret = ctx(cl.fn, args...)
        (ctx.weight, ret)
    end
    blank = ParameterStore()
    _, back = Zygote.pullback(fn, cl.args, blank)
    arg_grads, ps_grad = back((1.0, ret_grad))
    if !(ps_grad isa Nothing)
        for (addr, grad) in ps_grad.params
            push!(param_grads, addr, scaler .* grad)
        end
    end
    return arg_grads
end

function accumulate_parameter_gradients!(sel, initial_params, param_grads, cl::HierarchicalCallSite, ret_grad::Tuple, scaler::Float64 = 1.0)
    fn = (args, params) -> begin
        ctx = ParameterBackpropagate(cl, sel, initial_params, params, param_grads)
        ret = ctx(cl.fn, args...)
        (ctx.weight, ret)
    end
    blank = ParameterStore()
    _, back = Zygote.pullback(fn, cl.args, blank)
    arg_grads, ps_grad = back((1.0, ret_grad...))
    if !(ps_grad isa Nothing)
        for (addr, grad) in ps_grad.params
            push!(param_grads, addr, scaler .* grad)
        end
    end
    return arg_grads
end

function accumulate_parameter_gradients!(sel, initial_params, param_grads, cl::VectorizedCallSite{typeof(markov)}, ret_grad, scaler::Float64 = 1.0) where T <: CallSite
    fn = (args, params) -> begin
        ctx = ParameterBackpropagate(cl, sel, initial_params, params, param_grads)
        ret = ctx(markov, cl.fn, cl.len, args...)
        (ctx.weight, ret)
    end
    blank = ParameterStore()
    _, back = Zygote.pullback(fn, cl.args, blank)
    arg_grads, ps_grad = back((1.0, ret_grad))
    if !(ps_grad isa Nothing)
        for (addr, grad) in ps_grad.params
            push!(param_grads, addr, scaler .* grad)
        end
    end
    return arg_grads
end

function accumulate_parameter_gradients!(sel, initial_params, param_grads, cl::VectorizedCallSite{typeof(plate)}, ret_grad, scaler::Float64 = 1.0) where T <: CallSite
    fn = (args, params) -> begin
        ctx = ParameterBackpropagate(cl, sel, initial_params, params, param_grads)
        ret = ctx(plate, cl.fn, args)
        (ctx.weight, ret)
    end
    blank = ParameterStore()
    _, back = Zygote.pullback(fn, cl.args, blank)
    arg_grads, ps_grad = back((1.0, ret_grad))
    if !(ps_grad isa Nothing)
        for (addr, grad) in ps_grad.params
            push!(param_grads, addr, scaler .* grad)
        end
    end
    return arg_grads
end

# ------------ Compute choice gradients ------------ #

function filter!(choice_grads, cl::HierarchicalCallSite, grad_tr::NamedTuple, sel::K) where K <: UnconstrainedSelection
    values = ConstrainedHierarchicalSelection()
    for (k, v) in dump_top(cl.trace)
        has_top(sel, k) && begin
            push!(values, k, v.val)
            push!(choice_grads, k, grad_tr.trace.choices[k].val)
        end
    end
    return values
end

function filter!(choice_grads, cl::HierarchicalCallSite, grad_tr, sel::K) where K <: UnconstrainedSelection
    values = ConstrainedHierarchicalSelection()
    for (k, v) in dump_top(cl.trace)
        has_top(sel, k) && begin
            push!(values, k, v.val)
        end
    end
    return values
end

function choice_gradients(initial_params::P, choice_grads, choice_selection::K, cl, ret_grad) where {P <: Parameters, K <: UnconstrainedSelection}
    fn = (args, call) -> begin
        ctx = ChoiceBackpropagate(call, initial_params, ParameterStore(), choice_grads, choice_selection)
        ret = ctx(call.fn, args...)
        (ctx.weight, ret)
    end
    _, back = Zygote.pullback(fn, cl.args, cl)
    arg_grads, grad_ref = back((1.0, ret_grad))
    choice_vals = filter!(choice_grads, cl, grad_ref, choice_selection)
    return arg_grads, choice_vals, choice_grads
end

function choice_gradients(fixed::S, initial_params::P, choice_grads, choice_selection::K, cl, ret_grad) where {S <: ConstrainedSelection, P <: Parameters, K <: UnconstrainedSelection}
    fn = (args, call) -> begin
        ctx = ChoiceBackpropagate(call, fixed, initial_params, ParameterStore(), choice_grads, choice_selection)
        ret = ctx(call.fn, args...)
        (ctx.weight, ret)
    end
    _, back = Zygote.pullback(fn, cl.args, cl)
    arg_grads, grad_ref = back((1.0, ret_grad))
    choice_vals = filter!(choice_grads, cl, grad_ref, choice_selection)
    return arg_grads, choice_vals, choice_grads
end

# ------------ get_choice_gradients ------------ #

function get_choice_gradients(cl::T, ret_grad) where T <: CallSite
    choice_grads = Gradients()
    choice_selection = UnconstrainedAllSelection()
    _, vals, _ = choice_gradients(Parameters(), choice_grads, choice_selection, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(fixed::S, cl::T, ret_grad) where {S <: ConstrainedSelection, T <: CallSite}
    choice_grads = Gradients()
    choice_selection = UnconstrainedAllSelection()
    _, vals, _ = choice_gradients(fixed, Parameters(), choice_grads, choice_selection, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(ps::P, cl::T, ret_grad) where {P <: Parameters, T <: CallSite}
    choice_grads = Gradients()
    choice_selection = UnconstrainedAllSelection()
    _, vals, _ = choice_gradients(ps, choice_grads, choice_selection, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(fixed::S, ps::P, cl::T, ret_grad) where {S <: ConstrainedSelection, P <: Parameters, T <: CallSite}
    choice_grads = Gradients()
    choice_selection = UnconstrainedAllSelection()
    _, vals, _ = choice_gradients(fixed, ps, choice_grads, choice_selection, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(sel::K, cl::T, ret_grad) where {T <: CallSite, K <: UnconstrainedSelection}
    choice_grads = Gradients()
    _, vals, _ = choice_gradients(Parameters(), choice_grads, sel, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(sel::K, ps::P, cl::T, ret_grad) where {T <: CallSite, K <: UnconstrainedSelection, P <: Parameters}
    choice_grads = Gradients()
    _, vals, _ = choice_gradients(ps, choice_grads, sel, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(sel::K, fixed::S, cl::T, ret_grad) where {K <: UnconstrainedSelection, S <: ConstrainedSelection, T <: CallSite}
    choice_grads = Gradients()
    _, vals, _ = choice_gradients(Parameters(), choice_grads, sel, cl, ret_grad)
    return vals, choice_grads
end

function get_choice_gradients(sel::K, fixed::S, ps::P, cl::T, ret_grad) where {T <: CallSite, K <: UnconstrainedSelection, S <: ConstrainedSelection, P <: Parameters}
    choice_grads = Gradients()
    _, vals, _ = choice_gradients(ps, choice_grads, sel, cl, ret_grad)
    return vals, choice_grads
end

# ------------ get_learnable_gradients ------------ #

function get_learnable_gradients(ps::P, cl::HierarchicalCallSite, ret_grad, scaler::Float64 = 1.0) where P <: Parameters
    param_grads = Gradients()
    accumulate_parameter_gradients!(selection(), ps, param_grads, cl, ret_grad, scaler)
    return param_grads
end

function get_learnable_gradients(sel::K, ps::P, cl::HierarchicalCallSite, ret_grad, scaler::Float64 = 1.0) where {K <: ConstrainedSelection, P <: Parameters}
    param_grads = Gradients()
    accumulate_parameter_gradients!(sel, ps, param_grads, cl, ret_grad, scaler)
    return param_grads
end

function get_learnable_gradients(ps::P, cl::VectorizedCallSite, ret_grad, scaler::Float64 = 1.0) where P <: Parameters
    param_grads = Gradients()
    accumulate_parameter_gradients!(selection(), ps, param_grads, cl, ret_grad, scaler)
    for k in keys(param_grads.tree)
        return param_grads.tree[k]
    end
end

function get_learnable_gradients(sel::K, ps::P, cl::VectorizedCallSite, ret_grad, scaler::Float64 = 1.0) where {K <: ConstrainedSelection, P <: Parameters}
    param_grads = Gradients()
    accumulate_parameter_gradients!(sel, ps, param_grads, cl, ret_grad, scaler)
    for k in keys(param_grads.tree)
        return param_grads.tree[k]
    end
end

# ------------ train ------------ #

function train(ps::P, fn::Function, args...; opt = ADAM(0.05, (0.9, 0.8)), iters = 1000) where P <: Parameters
    for i in 1 : iters
        _, cl = simulate(ps, fn, args...)
        grads = get_learnable_gradients(ps, cl, 1.0)
        ps = update_learnables(opt, ps, grads)
    end
    return ps
end

function train(sel::K, ps::P, fn::Function, args...; opt = ADAM(0.05, (0.9, 0.8)), iters = 1000) where {K <: ConstrainedSelection, P <: Parameters}
    for i in 1 : iters
        _, cl, _ = generate(sel, ps, fn, args...)
        grads = get_learnable_gradients(sel, ps, cl, 1.0)
        ps = update_learnables(opt, ps, grads)
    end
    return ps
end

# ------------ includes ------------ #

include("hierarchical/backpropagate.jl")
include("plate/backpropagate.jl")
include("markov/backpropagate.jl")
include("factor/backpropagate.jl")

# ------------ Documentation ------------ #

@doc(
"""
```julia
mutable struct ParameterBackpropagateContext{T <: Trace} <: BackpropagationContext
    tr::T
    weight::Float64
    initial_params::Parameters
    params::ParameterStore
    param_grads::Gradients
end
```
`ParameterBackpropagateContext` is used to compute the gradients of parameters with respect to following objective:

Outer constructors:
```julia
ParameterBackpropagate(tr::T, params) where T <: Trace = ParameterBackpropagateContext(tr, 0.0, params, Gradients())
ParameterBackpropagate(tr::T, params, param_grads::Gradients) where {T <: Trace, K <: UnconstrainedSelection} = ParameterBackpropagateContext(tr, 0.0, params, param_grads)
```
""", ParameterBackpropagateContext)

@doc(
"""
```julia
mutable struct ChoiceBackpropagateContext{T <: Trace} <: BackpropagationContext
    tr::T
    weight::Float64
    initial_params::Parameters
    params::ParameterStore
    param_grads::Gradients
end
```
`ChoiceBackpropagateContext` is used to compute the gradients of choices with respect to following objective:

Outer constructors:
```julia
ChoiceBackpropagate(tr::T, init_params, params, choice_grads) where {T <: Trace, K <: UnconstrainedSelection} = ChoiceBackpropagateContext(tr, 0.0, params, choice_grads, UnconstrainedAllSelection())
ChoiceBackpropagate(tr::T, init_params, params, choice_grads, sel::K) where {T <: Trace, K <: UnconstrainedSelection} = ChoiceBackpropagateContext(tr, 0.0, params, choice_grads, sel)
```
""", ChoiceBackpropagateContext)

@doc(
"""
```julia
gradients = get_choice_gradients(params, cl::T, ret_grad) where T <: CallSite
gradients = get_choice_gradients(cl::T, ret_grad) where T <: CallSite
```

Returns a `Gradients` object which tracks the gradients with respect to the objective of random choices with differentiable `logpdf` in the program.
""", get_choice_gradients)

@doc(
"""
```julia
gradients = get_learnable_gradients(params, cl::T, ret_grad, scaler::Float64 = 1.0) where T <: CallSite
```

Returns a `Gradients` object which tracks the gradients of the objective with respect to parameters in the program.
""", get_learnable_gradients)
