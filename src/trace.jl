import Base: rand
rand(addr::Address, d::Distribution{T}) where T = rand(d)
rand(addr::Address, fn::Function, args...) = fn(args...)
learnable(addr::Address, p::T) where T = p

abstract type RecordSite end
abstract type CallSite <: RecordSite end
abstract type LearnableSite <: RecordSite end

struct ChoiceSite{T} <: RecordSite
    score::Float64
    val::T
end
get_score(cs::ChoiceSite) = cs.score

struct ParameterSite{T} <: LearnableSite
    val::T
end

# ------------ Hierarchical trace ------------ #

abstract type Trace end

@dynamo function (tr::Trace)(a...)
    ir = IR(a...)
    ir == nothing && return
    recur!(ir)
    return ir
end

mutable struct HierarchicalTrace <: Trace
    calls::Dict{Address, CallSite}
    choices::Dict{Address, ChoiceSite}
    params::Dict{Address, LearnableSite}
    score::Float64
    function HierarchicalTrace()
        new(Dict{Address, CallSite}(), 
            Dict{Address, ChoiceSite}(),
            Dict{Address, LearnableSite}(),
            0.0)
    end
end
Trace() = HierarchicalTrace()
has_choice(tr::HierarchicalTrace, addr) = haskey(tr.choices, addr)
has_call(tr::HierarchicalTrace, addr::Address) = haskey(tr.calls, addr)
get_call(tr::HierarchicalTrace, addr::Address) = tr.calls[addr]
get_choice(tr::HierarchicalTrace, addr) = tr.choices[addr]
get_param(tr::HierarchicalTrace, addr) = tr.params[addr]
function get_call(tr::HierarchicalTrace, addr::Pair)
    get_call(tr.calls[addr[1]], addr[2])
end
function add_choice!(tr::HierarchicalTrace, addr, cs::ChoiceSite)
    tr.score += get_score(cs)
    tr.choices[addr] = cs
end
function add_call!(tr::HierarchicalTrace, addr, cs::CallSite)
    tr.score += get_score(cs)
    tr.calls[addr] = cs
end
get_score(tr::HierarchicalTrace) = tr.score

# ------------ Call sites ------------ #

mutable struct BlackBoxCallSite{T <: Trace, J, K} <: CallSite
    trace::T
    fn::Function
    args::J
    ret::K
end
has_choice(bbcs::BlackBoxCallSite, addr) = haskey(bbcs.tr.choices, addr)
has_call(bbcs::BlackBoxCallSite, addr) = haskey(bbcs.tr.calls, addr)
get_call(bbcs::BlackBoxCallSite, addr) = bbcs.tr.calls[addr]
get_score(bbcs::BlackBoxCallSite) = get_score(bbcs.trace)

mutable struct VectorizedCallSite{F <: Function, T <: Trace, J, K} <: CallSite
    subtraces::Vector{T}
    score::Float64
    fn::Function
    args::J
    ret::Vector{K}
    function VectorizedCallSite{F}(sub::Vector{T}, sc::Float64, fn::Function, args::J, ret::Vector{K}) where {F <: Function, T <: Trace, J, K}
        new{F, T, J, K}(sub, sc, fn, args, ret)
    end
end
function has_choice(vcs::VectorizedCallSite, addr)
    for tr in vcs.subtraces
        has_choice(tr, addr) && return true
    end
    return false
end
function has_call(vcs::VectorizedCallSite, addr)
    for tr in vcs.subtraces
        has_call(tr, addr) && return true
    end
    return false
end
function get_call(vcs::VectorizedCallSite, addr)
    for tr in vcs.subtraces
        has_call(tr, addr) && return get_call(tr, addr)
    end
    error("VectorizedCallSite (get_call): no call at $addr.")
end
get_score(vcs::VectorizedCallSite) = vcs.score

# ------------ Direct execution with trace ------------ #

@inline function (tr::HierarchicalTrace)(fn::typeof(rand), addr::Address, d::Distribution{T}) where T
    s = rand(d)
    add_choice!(tr, addr, ChoiceSite(logpdf(d, s), s))
    return s
end

@inline function (tr::HierarchicalTrace)(fn::typeof(learnable), addr::Address, p::T) where T
    haskey(tr.params, addr) && return get_param(tr, addr)
    tr.params[addr] = ParameterSite(p)
    return p
end

@inline function (tr::HierarchicalTrace)(fn::typeof(rand), addr::Address, call::Function, args...)
    ret, cl = trace(call, args...)
    add_call!(tr, addr, cl)
    return ret
end

# Vectorized foldr call.
@inline function (tr::HierarchicalTrace)(c::typeof(foldr), addr::Address, call::Function, len::Int, args...)
    ret, cl = trace(call, args...)
    v_ret = Vector{typeof(ret)}(undef, len)
    v_tr = Vector{HierarchicalTrace}(undef, len)
    v_ret[1] = ret
    v_tr[1] = cl.trace
    for i in 2:len
        ret, cl = trace(call, v_ret[i-1]...)
        v_ret[i] = ret
        v_tr[i] = cl.trace
    end
    sc = sum(map(v_tr) do tr
                    get_score(tr)
                end)
    add_call!(tr, addr, VectorizedCallSite{typeof(foldr)}(v_tr, sc, call, args, v_ret))
    return v_ret
end

# Vectorized map call.
@inline function (tr::HierarchicalTrace)(c::typeof(map), addr::Address, call::Function, args::Vector)
    len = length(args)
    ret, cl = trace(call, args[1]...)
    v_ret = Vector{typeof(ret)}(undef, len)
    v_tr = Vector{HierarchicalTrace}(undef, len)
    v_ret[1] = ret
    v_tr[1] = cl.trace
    for i in 2:len
        ret, cl = trace(call, args[i]...)
        v_ret[i] = ret
        v_tr[i] = cl.trace
    end
    sc = sum(map(v_tr) do tr
                    get_score(tr)
                end)
    add_call!(tr, addr, VectorizedCallSite{typeof(map)}(v_tr, sc, call, args, v_ret))
    return v_ret
end

# ------------ getindex ------------ #

import Base.getindex
getindex(cs::ChoiceSite, addr::Address) = nothing
getindex(cs::BlackBoxCallSite, addr) = getindex(cs.trace, addr)
getindex(vcs::VectorizedCallSite, addr::Int) = cs.subtraces[addr]
function getindex(vcs::VectorizedCallSite, addr::Pair)
    getindex(vcs.subtraces[addr[1]], addr[2])
end
unwrap(cs::ChoiceSite) = cs.val
unwrap(cs::BlackBoxCallSite) = cs.ret
unwrap(cs::VectorizedCallSite) = cs.ret
function getindex(tr::HierarchicalTrace, addr::Address)
    if has_choice(tr, addr)
        return unwrap(get_choice(tr, addr))
    else
        return nothing
    end
end
function getindex(tr::HierarchicalTrace, addr::Pair)
    if has_call(tr, addr[1])
        return getindex(get_call(tr, addr[1]), addr[2])
    else
        return nothing
    end
end

# ------------ haskey ------------ #

import Base.haskey
haskey(cs::ChoiceSite, addr::Address) = false
haskey(cs::BlackBoxCallSite, addr) = haskey(cs.trace, addr)
function haskey(vcs::VectorizedCallSite, addr::Pair)
    addr[1] <= length(vcs.subtraces) && haskey(vcs.subtraces[addr[1]], addr[2])
end
function Base.haskey(tr::HierarchicalTrace, addr::Address)
    has_choice(tr, addr)
end
function Base.haskey(tr::HierarchicalTrace, addr::Pair)
    if has_call(tr, addr[1])
        return Base.haskey(get_call(tr, addr[1]), addr[2])
    else
        return false
    end
end

# ------------ Convenience ------------ #

function Jaynes.trace(fn::Function, args...)
    tr = Trace()
    ret = tr(fn, args...)
    return ret, BlackBoxCallSite(tr, fn, args, ret)
end

# ------------ Documentation ------------ #

@doc(
"""
```julia
abstract type Trace end
```
Abstract base type of all traces.
""", Trace)

@doc(
"""
```julia
mutable struct HierarchicalTrace <: Trace
    calls::Dict{Address, CallSite}
    choices::Dict{Address, ChoiceSite}
    params::Dict{Address, LearnableSite}
    score::Float64
    function HierarchicalTrace()
        new(Dict{Address, CallSite}(), 
            Dict{Address, ChoiceSite}(),
            Dict{Address, LearnableSite}(),
            0.0)
    end
end
```
Structured execution trace with tracked randomness in a function call.
""", HierarchicalTrace)

@doc(
"""
```julia
struct ChoiceSite{T} <: RecordSite
    score::Float64
    val::T
end
```
A record of a random sample at an addressed `rand` call with a `Distribution` instance. Keeps the value of the random sample and the `logpdf` score.
""", ChoiceSite)

@doc(
"""
```julia
abstract type CallSite <: RecordSite end
```
Abstract base type of all call sites.
""", CallSite)

@doc(
"""
```julia
mutable struct BlackBoxCallSite{T <: Trace, J, K} <: CallSite
    trace::T
    fn::Function
    args::J
    ret::K
end
```
A record of a black-box call (e.g. no special tracer language features). Records the `fn` and `args` for the call, as well as the `ret` return value.
""", BlackBoxCallSite)

@doc(
"""
```julia
mutable struct VectorizedCallSite{F <: Function, T <: Trace, J, K} <: CallSite
    subtraces::Vector{T}
    score::Float64
    fn::Function
    args::J
    ret::Vector{K}
end
```
A record of a call site using the special `map` and `foldr` tracer language features. Informs the tracer that the call conforms to a special pattern of randomness dependency, which allows the storing of `Trace` instances sequentially in a vector.
""", VectorizedCallSite)

@doc(
"""
```julia
ret, black_box_call_site = Jaynes.trace(fn::Function, args...)
```
Convenience function which traces the call for addressed randomness, returns the return value and a call site representation.
""", trace)
