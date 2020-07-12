import Base: haskey, getindex, push!, merge!, union, isempty, merge
import Base: +

# ------------ Selection ------------ #

# Abstract type for a sort of query language for addresses within a particular method body.
abstract type Selection end
abstract type UtilitySelection <: Selection end

# ------------ Lightweight visitor ------------ #

struct Visitor <: UtilitySelection
    tree::Dict{Address, Visitor}
    addrs::Vector{Address}
    Visitor() = new(Dict{Address, Visitor}(), Address[])
end

push!(vs::Visitor, addr::Address) = push!(vs.addrs, addr)

function visit!(vs::Visitor, addr::Address)
    addr in vs.addrs && error("VisitorError (visit!): already visited this address.")
    push!(vs, addr)
end

function set_sub!(vs::Visitor, addr::Address, sub::Visitor)
    haskey(vs.tree, addr) && error("VisitorError (set_sub!): already visited this address.")
    vs.tree[addr] = sub
end

function has_sub(vs::Visitor, addr::Address)
    return haskey(vs.tree, addr)
end

function get_sub(vs::Visitor, addr::Address)
    haskey(vs.tree, addr) && return vs.tree[addr]
    error("VisitorError (get_sub): sub not defined at $addr.")
end

function has_query(vs::Visitor, addr::Address)
    return addr in vs.addrs
end

isempty(vs::Visitor) = isempty(vs.tree) && isempty(vs.addrs)

# ------------ Gradients ------------ #

struct Gradients <: UtilitySelection
    tree::Dict{Address, Gradients}
    utility::Dict{Address, Any}
    Gradients() = new(Dict{Address, Gradients}(), Dict{Address, Any}())
end

has_grad(ps::Gradients, addr) = haskey(ps.utility, addr)

get_grad(ps::Gradients, addr) = getindex(ps.utility, addr)

has_sub(ps::Gradients, addr) = haskey(ps.tree, addr)

get_sub(ps::Gradients, addr) = getindex(ps.tree, addr)

function push!(ps::Gradients, addr, val)
    has_grad(ps, addr) && begin
        ps.utility[addr] += val
        return
    end
    ps.utility[addr] = val
end

Zygote.@adjoint Gradients(tree, utility) = Gradients(tree, utility), s_grad -> (nothing, nothing)

function merge(sel1::Gradients,
               sel2::Gradients)
    utility = merge(sel1.utility, sel2.utility)
    tree = Dict{Address, Gradients}()
    for k in setdiff(keys(sel2.tree), keys(sel1.tree))
        tree[k] = sel2.tree[k]
    end
    for k in setdiff(keys(sel1.tree), keys(sel2.tree))
        tree[k] = sel1.tree[k]
    end
    for k in intersect(keys(sel1.tree), keys(sel2.tree))
        tree[k] = merge(sel1.tree[k], sel2.tree[k])
    end
    return Gradients(tree, utility)
end

+(a_grads::Gradients, b_grads::Gradients) = merge(a_grads, b_grads)

# ------------ LearnableParameters ------------ #

struct LearnableParameters <: UtilitySelection
    tree::Dict{Address, LearnableParameters}
    utility::Dict{Address, Any}
    LearnableParameters() = new(Dict{Address, LearnableParameters}(), Dict{Address, Any}())
end

has_param(ps::LearnableParameters, addr) = haskey(ps.utility, addr)

get_param(ps::LearnableParameters, addr) = getindex(ps.utility, addr)

has_sub(ps::LearnableParameters, addr) = haskey(ps.tree, addr)

get_sub(ps::LearnableParameters, addr) = getindex(ps.tree, addr)

function push!(ps::LearnableParameters, addr, val)
    ps.utility[addr] = val
end

Zygote.@adjoint LearnableParameters(tree, utility) = LearnableParameters(tree, utility), s_grad -> (nothing, nothing)

function merge(sel1::LearnableParameters,
               sel2::LearnableParameters)
    utility = merge(sel1.utility, sel2.utility)
    tree = Dict{Address, Gradients}()
    for k in setdiff(keys(sel2.tree), keys(sel1.tree))
        tree[k] = sel2.tree[k]
    end
    for k in setdiff(keys(sel1.tree), keys(sel2.tree))
        tree[k] = sel1.tree[k]
    end
    for k in intersect(keys(sel1.tree), keys(sel2.tree))
        tree[k] = merge(sel1.tree[k], sel2.tree[k])
    end
    return LearnableParameters(tree, utility)
end

+(a::LearnableParameters, b::LearnableParameters) = merge(a, b)

function update!(a::LearnableParameters, b::Gradients)
    for (k, v) in a.utility
        if has_grad(b, k)
            a.utility[k] = v + get_grad(b, k)
        end
    end

    for (k, v) in a.tree
        if has_sub(b, k)
            update!(v, get_sub(b, k))
        end
    end
end

# ------------ Constrained and unconstrained selections ------------ #

abstract type ConstrainedSelection end
abstract type UnconstrainedSelection end
abstract type SelectQuery <: Selection end
abstract type ConstrainedSelectQuery <: SelectQuery end
abstract type UnconstrainedSelectQuery <: SelectQuery end

# ------------ Constraints to direct addresses ------------ #

struct ConstrainedSelectByAddress <: ConstrainedSelectQuery
    query::Dict{Address, Any}
    ConstrainedSelectByAddress() = new(Dict{Address, Any}())
    ConstrainedSelectByAddress(d::Dict{Address, Any}) = new(d)
end

has_query(csa::ConstrainedSelectByAddress, addr) = haskey(csa.query, addr)
dump_queries(csa::ConstrainedSelectByAddress) = keys(csa.query)
get_query(csa::ConstrainedSelectByAddress, addr) = getindex(csa.query, addr)
isempty(csa::ConstrainedSelectByAddress) = isempty(csa.query)

# ----------- Selection to direct addresses ------------ #

struct UnconstrainedSelectByAddress <: UnconstrainedSelectQuery
    query::Vector{Address}
    UnconstrainedSelectByAddress() = new(Address[])
end

has_query(csa::UnconstrainedSelectByAddress, addr) = addr in csa.query
dump_queries(csa::UnconstrainedSelectByAddress) = keys(csa.query)
isempty(csa::UnconstrainedSelectByAddress) = isempty(csa.query)

# ------------ Constrain anywhere ------------ #

struct ConstrainedAnywhereSelection{T <: ConstrainedSelectQuery} <: ConstrainedSelection
    query::T
    ConstrainedAnywhereSelection(obs::Vector{Tuple{T, K}}) where {T <: Any, K} = new{ConstrainedSelectByAddress}(ConstrainedSelectByAddress(Dict{Address, Any}(obs)))
    ConstrainedAnywhereSelection(obs::Tuple{T, K}...) where {T <: Any, K} = new{ConstrainedSelectByAddress}(ConstrainedSelectByAddress(Dict{Address, Any}(collect(obs))))
end

has_query(cas::ConstrainedAnywhereSelection, addr) = has_query(cas.query, addr)
dump_queries(cas::ConstrainedAnywhereSelection) = dump_queries(cas.query)
get_query(cas::ConstrainedAnywhereSelection, addr) = get_query(cas.query, addr)
get_sub(cas::ConstrainedAnywhereSelection, addr) = cas
isempty(cas::ConstrainedAnywhereSelection) = isempty(cas.query)

# ------------ Unconstrained select anywhere ------------ #

struct UnconstrainedAnywhereSelection{T <: UnconstrainedSelectQuery} <: UnconstrainedSelection
    query::T
    UnconstrainedAnywhereSelection(obs::Vector{Tuple{T, K}}) where {T <: Any, K} = new{UnconstrainedSelectByAddress}(UnconstrainedSelectByAddress(Dict{Address, Any}(obs)))
    UnconstrainedAnywhereSelection(obs::Tuple{T, K}...) where {T <: Any, K} = new{UnconstrainedSelectByAddress}(UnconstrainedSelectByAddress(Dict{Address, Any}(collect(obs))))
end

has_query(cas::UnconstrainedAnywhereSelection, addr) = has_query(cas.query, addr)
dump_queries(cas::UnconstrainedAnywhereSelection) = dump_queries(cas.query)
get_sub(cas::UnconstrainedAnywhereSelection, addr) = cas
isempty(cas::UnconstrainedAnywhereSelection) = isempty(cas.query)

struct UnconstrainedAllSelection <: UnconstrainedSelection end

has_query(uas::UnconstrainedAllSelection, addr) = true
get_sub(uas::UnconstrainedAllSelection, addr) = uas
isempty(uas::UnconstrainedAllSelection) = false

# ------------ Constrain in call hierarchy ------------ #

struct ConstrainedHierarchicalSelection{T <: ConstrainedSelectQuery} <: ConstrainedSelection
    tree::Dict{Union{Int, Address}, ConstrainedSelection}
    query::T
    ConstrainedHierarchicalSelection() = new{ConstrainedSelectByAddress}(Dict{Union{Int, Address}, ConstrainedHierarchicalSelection}(), ConstrainedSelectByAddress())
    ConstrainedHierarchicalSelection(csa::T) where T <: ConstrainedSelectQuery = new{T}(Dict{Union{Int, Address}, ConstrainedHierarchicalSelection}(), csa)
end

function get_sub(chs::ConstrainedHierarchicalSelection, addr)
    haskey(chs.tree, addr) && return chs.tree[addr]
    return ConstrainedHierarchicalSelection()
end

function get_sub(chs::ConstrainedHierarchicalSelection, addr::Pair)
    haskey(chs.tree, addr[1]) && return get_sub(chs.tree[addr[1]], addr[2])
    return ConstrainedHierarchicalSelection()
end

has_query(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Address = has_query(chs.query, addr)
function has_query(chs::ConstrainedHierarchicalSelection, addr::Pair)
    if haskey(chs.tree, addr[1])
        return has_query(get_sub(chs, addr[1]), addr[2])
    end
    return false
end
dump_queries(chs::ConstrainedHierarchicalSelection) = dump_queries(chs.query)
get_query(chs::ConstrainedHierarchicalSelection, addr) = get_query(chs.query, addr)
isempty(chs::ConstrainedHierarchicalSelection) = isempty(chs.tree) && isempty(chs.query)

# ------------ Unconstrained selection in call hierarchy ------------ #

struct UnconstrainedHierarchicalSelection{T <: UnconstrainedSelectQuery} <: UnconstrainedSelection
    tree::Dict{Address, UnconstrainedHierarchicalSelection}
    query::T
    UnconstrainedHierarchicalSelection() = new{UnconstrainedSelectByAddress}(Dict{Address, UnconstrainedHierarchicalSelection}(), UnconstrainedSelectByAddress())
end

function get_sub(uhs::UnconstrainedHierarchicalSelection, addr)
    haskey(uhs.tree, addr) && return uhs.tree[addr]
    return UnconstrainedHierarchicalSelection()
end

function get_sub(uhs::UnconstrainedHierarchicalSelection, addr::Pair)
    haskey(uhs.tree, addr[1]) && return get_sub(uhs.tree[addr[1]], addr[2])
    return UnconstrainedHierarchicalSelection()
end

has_query(uhs::UnconstrainedHierarchicalSelection, addr) = has_query(uhs.query, addr)
dump_queries(uhs::UnconstrainedHierarchicalSelection) = dump_queries(uhs.query)
isempty(uhs::UnconstrainedHierarchicalSelection) = isempty(uhs.tree) && isempty(uhs.query)

# ------------ Union of constraints ------------ #

struct ConstrainedUnionSelection <: ConstrainedSelection
    query::Vector{ConstrainedSelection}
end

function has_query(cus::ConstrainedUnionSelection, addr)
    for q in cus.query
        has_query(q, addr) && return true
    end
    return false
end
function dump_queries(cus::ConstrainedUnionSelection)
    arr = Address[]
    for q in cus.query
        append!(arr, collect(dump_queries(q)))
    end
    return arr
end
function get_query(cus::ConstrainedUnionSelection, addr)
    for q in cus.query
        has_query(q, addr) && return get_query(q, addr)
    end
    error("ConstrainedUnionSelection (get_query): query not defined for $addr.")
end

function get_sub(cus::ConstrainedUnionSelection, addr)
    return ConstrainedUnionSelection(map(cus.query) do q
                                         get_sub(q, addr)
                                     end)
end

isempty(cus::ConstrainedUnionSelection) = isempty(cus.query)

# ------------ Unconstrained union selection ------------ #

struct UnconstrainedUnionSelection <: UnconstrainedSelection
    query::Vector{UnconstrainedSelection}
end

function has_query(uus::UnconstrainedUnionSelection, addr)
    for q in uus.query
        has_query(q, addr) && return true
    end
    return false
end

function dump_queries(uus::UnconstrainedUnionSelection)
    arr = Address[]
    for q in uus.query
        append!(arr, collect(dump_queries(q)))
    end
    return arr
end

function get_sub(uus::UnconstrainedUnionSelection, addr)
    return UnconstrainedUnionSelection(map(uus.query) do q
                                           get_sub(q, addr)
                                       end)
end

isempty(uus::UnconstrainedUnionSelection) = isempty(uus.query)

# ------------ Set operations on selections ------------ #

union(a::ConstrainedSelection...) = ConstrainedUnionSelection([a...])
function intersection(a::ConstrainedSelection...) end

# ------------ Selection builders ------------ #

function push!(sel::UnconstrainedSelectByAddress, addr::Symbol)
    push!(sel.query, addr)
end

function push!(sel::ConstrainedSelectByAddress, addr::Symbol, val)
    sel.query[addr] = val
end

function push!(sel::UnconstrainedSelectByAddress, addr::Pair{Symbol, Int64})
    push!(sel.query, addr)
end

function push!(sel::ConstrainedSelectByAddress, addr::Pair{Symbol, Int64}, val)
    sel.query[addr] = val
end

function push!(sel::UnconstrainedHierarchicalSelection, addr::Symbol)
    push!(sel.query, addr)
end

function push!(sel::ConstrainedHierarchicalSelection, addr::Symbol, val)
    push!(sel.query, addr, val)
end

function push!(sel::UnconstrainedHierarchicalSelection, addr::Pair{Symbol, Int64})
    push!(sel.query, addr)
end

function push!(sel::ConstrainedHierarchicalSelection, addr::Pair{Symbol, Int64}, val)
    push!(sel.query, addr, val)
end

function push!(sel::UnconstrainedHierarchicalSelection, addr::Pair)
    if !(haskey(sel.tree, addr[1]))
        new = UnconstrainedHierarchicalSelection()
        push!(new, addr[2])
        sel.tree[addr[1]] = new
    else
        push!(sel[addr[1]], addr[2])
    end
end

function push!(sel::ConstrainedHierarchicalSelection, addr::Pair, val)
    if !(haskey(sel.tree, addr[1]))
        new = ConstrainedHierarchicalSelection()
        push!(new, addr[2], val)
        sel.tree[addr[1]] = new
    else
        push!(get_sub(sel, addr[1]), addr[2], val)
    end
end

function UnconstrainedHierarchicalSelection(a::Vector{K}) where K <: Union{Symbol, Pair}
    top = UnconstrainedHierarchicalSelection()
    for addr in a
        push!(top, addr)
    end
    return top
end

function ConstrainedHierarchicalSelection(a::Vector{Tuple{K, T}}) where {T, K}
    top = ConstrainedHierarchicalSelection()
    for (addr, val) in a
        push!(top, addr, val)
    end
    return top
end

# ------------ Merging selections ------------ #

function merge!(sel1::ConstrainedSelectByAddress,
                sel2::ConstrainedSelectByAddress)
    Base.merge!(sel1.query, sel2.query)
end

function merge!(sel1::ConstrainedHierarchicalSelection,
                sel2::ConstrainedHierarchicalSelection)
    merge!(sel1.query, sel2.query)
    for k in keys(sel2.tree)
        if haskey(sel1.tree, k)
            merge!(sel1.tree[k], sel2.query[k])
        else
            sel1.tree[k] = sel2.query[k]
        end
    end
end

# ------------ Trace to constrained selection ------------ #

function site_push!(chs::ConstrainedHierarchicalSelection, addr::Address, cs::ChoiceSite)
    push!(chs, addr, cs.val)
end

function site_push!(chs::ConstrainedHierarchicalSelection, addr::Address, cs::BlackBoxCallSite)
    subtrace = cs.trace
    subchs = ConstrainedHierarchicalSelection()
    for k in keys(subtrace.calls)
        site_push!(subchs, k, subtrace.calls[k])
    end
    for k in keys(subtrace.choices)
        site_push!(subchs, k, subtrace.choices[k])
    end
    chs.tree[addr] = subchs
end

function site_push!(chs::ConstrainedHierarchicalSelection, addr::Address, cs::VectorizedCallSite)
    for (k, subtrace) in enumerate(cs.subtraces)
        subchs = ConstrainedHierarchicalSelection()
        for k in keys(subtrace.calls)
            site_push!(subchs, k, subtrace.calls[k])
        end
        for k in keys(subtrace.choices)
            site_push!(subchs, k, subtrace.choices[k])
        end
        chs.tree[addr] = subchs
    end
end

function push!(chs::ConstrainedHierarchicalSelection, tr::HierarchicalTrace)
    for k in keys(tr.calls)
        site_push!(chs, k, tr.calls[k])
    end
    for k in keys(tr.choices)
        site_push!(chs, k, tr.choices[k])
    end
end

function get_selection(tr::HierarchicalTrace)
    top = ConstrainedHierarchicalSelection()
    push!(top, tr)
    return top
end

function get_selection(cl::BlackBoxCallSite)
    top = ConstrainedHierarchicalSelection()
    push!(top, cl.trace)
    return top
end

# ------------ Trace to parameters ------------ #

function site_push!(chs::LearnableParameters, addr::Address, cs::LearnableSite)
    push!(chs, addr, cs.val)
end

function site_push!(chs::LearnableParameters, addr::Address, cs::BlackBoxCallSite)
    subtrace = cs.trace
    subchs = LearnableParameters()
    for (k, v) in subtrace.calls
        site_push!(subchs, k, v)
    end
    for (k, v) in subtrace.params
        site_push!(subchs, k, v)
    end
    chs.tree[addr] = subchs
end

function push!(chs::LearnableParameters, tr::HierarchicalTrace)
    for (k, v) in tr.calls
        site_push!(chs, k, v)
    end
    for (k, v) in tr.params
        site_push!(chs, k, v)
    end
end

function get_parameters(tr::HierarchicalTrace)
    top = LearnableParameters()
    push!(top, tr)
    return top
end

function get_parameters(cl::BlackBoxCallSite)
    top = LearnableParameters()
    push!(top, cl.trace)
    return top
end

# ------------ Wrapper to builders ------------ #

selection() = ConstrainedHierarchicalSelection()

function selection(a::Vector{Tuple{K, T}}; anywhere = false) where {T, K}
    anywhere && return ConstrainedAnywhereSelection(a)
    return ConstrainedHierarchicalSelection(a)
end
function selection(a::Vector{K}) where K <: Union{Symbol, Pair}
    return UnconstrainedHierarchicalSelection(a)
end
function selection(a::Tuple{K, T}...) where {T, K <: Union{Symbol, Pair}}
    observations = Vector{Tuple{K, T}}(collect(a))
    return ConstrainedHierarchicalSelection(observations)
end
function selection(a::Address...)
    observations = Vector{Address}(collect(a))
    return UnconstrainedHierarchicalSelection(observations)
end

# ------------ Compare selections to visitors ------------ #

addresses(csa::ConstrainedSelectByAddress) = keys(csa.query)
addresses(usa::UnconstrainedSelectByAddress) = usa.query
function compare(chs::ConstrainedHierarchicalSelection, v::Visitor)::Bool
    for addr in addresses(chs.query)
        addr in v.addrs || return false
    end
    for addr in keys(chs.tree)
        haskey(v.tree, addr) || return false
        compare(chs.tree[addr], v.tree[addr]) || return false
    end
    return true
end

# ------------ Merge constrained selections and trace ------------ #

function merge(cl::T,
               sel::ConstrainedHierarchicalSelection) where T <: CallSite
    cl_selection = get_selection(cl)
    merge!(cl_selection, sel)
    return cl_selection
end

# ------------ Functional filter ------------ #

import Base.filter

function filter(k_fn::Function, v_fn::Function, query::ConstrainedSelectByAddress) where T <: Address
    top = ConstrainedSelectByAddress()
    for (k, v) in query.query
        k_fn(k) && v_fn(v) && push!(top, k, v)
    end
    return top
end

function filter(k_fn::Function, v_fn::Function, chs::ConstrainedHierarchicalSelection) where T <: Address
    top = ConstrainedHierarchicalSelection(filter(k_fn, v_fn, chs.query))
    for (k, v) in chs.tree
        top.tree[k] = filter(k_fn, v_fn, v)
    end
    return top
end

function filter(k_fn::Function, v_fn::Function, query::UnconstrainedSelectByAddress) where T <: Address
    top = UnconstrainedSelectByAddress()
    for k in query.query
        k_fn(k) && push!(top, k)
    end
    return top
end

function filter(k_fn::Function, chs::UnconstrainedHierarchicalSelection) where T <: Address
    top = UnconstrainedHierarchicalSelection(filter(k_fn, chs.query))
    for (k, v) in chs.tree
        top.tree[k] = filter(k_fn, v)
    end
    return top
end

# ------------ Pretty printing utility selections ------------ #

function collect!(par::T, addrs::Vector{Union{Symbol, Pair}}, chd::Dict{Union{Symbol, Pair}, Any}, chs::K) where {T <: Union{Symbol, Pair}, K <: UtilitySelection}
    for (k, v) in chs.utility
        push!(addrs, par => k)
        chd[par => k] = v
    end
    for (k, v) in chs.tree
        collect!(par => k, addrs, chd, v)
    end
end

function collect!(addrs::Vector{Union{Symbol, Pair}}, chd::Dict{Union{Symbol, Pair}, Any}, chs::K) where K <: UtilitySelection
    for (k, v) in chs.utility
        push!(addrs, k)
        chd[k] = v
    end
    for (k, v) in chs.tree
        collect!(k, addrs, chd, v)
    end
end

import Base.collect
function collect(chs::K) where K <: UtilitySelection
    addrs = Union{Symbol, Pair}[]
    chd = Dict{Union{Symbol, Pair}, Any}()
    collect!(addrs, chd, chs)
    return addrs, chd
end

function Base.display(chs::Gradients; show_values = false)
    println("  __________________________________\n")
    println("             Gradients\n")
    addrs, chd = collect(chs)
    if show_values
        for a in addrs
            println(" $(a) : $(chd[a])")
        end
    else
        for a in addrs
            println(" $(a)")
        end
    end
    println("  __________________________________\n")
end

function Base.display(chs::LearnableParameters; show_values = false)
    println("  __________________________________\n")
    println("             Parameters\n")
    addrs, chd = collect(chs)
    if show_values
        for a in addrs
            println(" $(a) : $(chd[a])")
        end
    else
        for a in addrs
            println(" $(a)")
        end
    end
    println("  __________________________________\n")
end

# ------------ Pretty printing ------------ #

function collect!(par, addrs, chd, query::ConstrainedSelectByAddress)
    for (k, v) in query.query
        push!(addrs, par => k)
        chd[par => k] = v
    end
end

function collect!(addrs, chd, query::ConstrainedSelectByAddress)
    for (k, v) in query.query
        push!(addrs, k)
        chd[k] = v
    end
end

function collect!(par::T, addrs::Vector{Union{Symbol, Pair}}, chd::Dict{Union{Symbol, Pair}, Any}, chs::ConstrainedHierarchicalSelection) where T <: Union{Symbol, Pair}
    collect!(par, addrs, chd, chs.query)
    for (k, v) in chs.tree
        collect!(par => k, addrs, chd, v)
    end
end

function collect!(addrs::Vector{Union{Symbol, Pair}}, chd::Dict{Union{Symbol, Pair}, Any}, chs::ConstrainedHierarchicalSelection)
    collect!(addrs, chd, chs.query)
    for (k, v) in chs.tree
        collect!(k, addrs, chd, v)
    end
end

import Base.collect
function collect(chs::ConstrainedHierarchicalSelection)
    addrs = Union{Symbol, Pair}[]
    chd = Dict{Union{Symbol, Pair}, Any}()
    collect!(addrs, chd, chs)
    return addrs, chd
end

function Base.display(chs::ConstrainedHierarchicalSelection; show_values = false)
    println("  __________________________________\n")
    println("             Constrained\n")
    addrs, chd = collect(chs)
    if show_values
        for a in addrs
            println(" $(a) : $(chd[a])")
        end
    else
        for a in addrs
            println(" $(a)")
        end
    end
    println("  __________________________________\n")
end

function collect!(par, addrs, query::UnconstrainedSelectByAddress)
    for k in query.query
        push!(addrs, par => k)
    end
end

function collect!(addrs, query::UnconstrainedSelectByAddress)
    for k in query.query
        push!(addrs, k)
    end
end

function collect!(par::T, addrs::Vector{Union{Symbol, Pair}}, chs::UnconstrainedHierarchicalSelection) where T <: Union{Symbol, Pair}
    collect!(par, chs.query)
    for (k, v) in chs.tree
        collect!(par => k, addrs, v)
    end
end

function collect!(addrs::Vector{Union{Symbol, Pair}}, chs::UnconstrainedHierarchicalSelection)
    collect!(addrs, chs.query)
    for (k, v) in chs.tree
        collect!(k, addrs, v)
    end
end

function collect(chs::UnconstrainedHierarchicalSelection)
    addrs = Union{Symbol, Pair}[]
    collect!(addrs, chs)
    return addrs
end

function Base.display(chs::UnconstrainedHierarchicalSelection)
    println("  __________________________________\n")
    println("              Selection\n")
    addrs = collect(chs)
    for a in addrs
        println(" $(a)")
    end
    println("  __________________________________\n")
end

function Base.display(chs::ConstrainedAnywhereSelection)
    println("  __________________________________\n")
    println("              Selection\n")
    addrs = Union{Symbol, Pair}[]
    chd = Dict{Address, Any}()
    collect!(addrs, chd, chs.query)
    for a in addrs
        println(" (Anywhere)   $(a) : $(chd[a])")
    end
    println("  __________________________________\n")
end
