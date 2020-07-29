# ------------ Constrain in call hierarchy ------------ #

struct ConstrainedHierarchicalSelection{T <: ConstrainedSelectQuery} <: ConstrainedSelection
    tree::Dict{Address, ConstrainedSelection}
    query::T
    ConstrainedHierarchicalSelection() = new{ConstrainedByAddress}(Dict{Address, ConstrainedHierarchicalSelection}(), ConstrainedByAddress())
    ConstrainedHierarchicalSelection(csa::T) where T <: ConstrainedSelectQuery = new{T}(Dict{Address, ConstrainedHierarchicalSelection}(), csa)
end

function get_sub(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Address
    haskey(chs.tree, addr) && return chs.tree[addr]
    return ConstrainedEmptySelection()
end
function get_sub(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Tuple
    isempty(addr) && return ConstrainedEmptySelection()
    length(addr) == 1 && return get_sub(chs, addr[1])
    haskey(chs.tree, addr[1]) && return get_sub(chs.tree[addr[1]], addr[2 : end])
    return ConstrainedEmptySelection()
end

function set_sub!(chs::ConstrainedHierarchicalSelection, addr::T, sub::K) where {T <: Address, K <: ConstrainedSelection}
    chs.tree[addr] = sub
end
function set_sub!(chs::ConstrainedHierarchicalSelection, addr::T, sub::K) where {T <: Tuple, K <: ConstrainedSelection}
    isempty(addr) && return
    if length(addr) == 1
        set_sub!(chs, addr[1], sub)
        return
    end
    set_sub!(chs.tree[addr[1]], addr[2 : end], sub)
end

function has_query(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Tuple
    isempty(addr) && return false
    length(addr) == 1 && return has_query(chs.query, addr[1])
    hd = addr[1]
    tl = addr[2 : end]
    haskey(chs.tree, hd) && return has_query(chs.tree[hd], tl)
    return false
end
has_query(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Address = has_query(chs.query, addr)

function get_query(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Address
    return get_query(chs.query, addr)
end
function get_query(chs::ConstrainedHierarchicalSelection, addr::T) where T <: Tuple
    isempty(addr) && return nothing
    length(addr) == 1 && return get_query(chs, addr[1])
    return get_query(chs.tree[addr[1]], addr[2 : end])
end
function getindex(chs::ConstrainedHierarchicalSelection, addr...)
    has_query(chs, addr) && return get_query(chs, addr)
    has_sub(chs, addr) && return get_sub(chs, addr)
    error("(getindex): no query or subselection at $addr.")
end

push_query!(toplevel::Set, k::K, q::T) where {K, T <: Address} = push!(toplevel, (k, q))
push_query!(toplevel::Set, k::K, q::T) where {K, T <: Tuple} = push!(toplevel, (k, q...))
function dump_queries(chs::ConstrainedHierarchicalSelection)
    toplevel = dump_queries(chs.query)
    for (k, v) in chs.tree
        for q in dump_queries(v)
            push_query!(toplevel, k, q)
        end
    end
    return toplevel
end

isempty(chs::ConstrainedHierarchicalSelection) = begin
    !isempty(chs.query) && return false
    for (k, v) in chs.tree
        !isempty(chs.tree[k]) && return false
    end
    return true
end

# Used to merge observations.
function merge!(sel1::ConstrainedHierarchicalSelection, sel2::ConstrainedHierarchicalSelection)
    merge!(sel1.query, sel2.query)
    for k in keys(sel2.tree)
        if haskey(sel1.tree, k)
            merge!(sel1.tree[k], sel2.tree[k])
        else
            sel1.tree[k] = sel2.tree[k]
        end
    end
end
function merge(cl::T, sel::ConstrainedHierarchicalSelection) where T <: CallSite
    cl_selection = get_selection(cl)
    merge!(cl_selection, sel)
    return cl_selection
end

# Used to build.
function push!(sel::ConstrainedHierarchicalSelection, addr::T, val) where T <: Address
    push!(sel.query, addr, val)
end
function push!(sel::ConstrainedHierarchicalSelection, addr::Tuple, val)
    fst = addr[1]
    tl = addr[2:end]
    isempty(tl) && begin
        push!(sel, fst, val)
        return
    end
    if !(haskey(sel.tree, fst))
        new = ConstrainedHierarchicalSelection()
        push!(new, tl, val)
        sel.tree[fst] = new
    else
        push!(get_sub(sel, addr[1]), tl, val)
    end
end

# Used for functional filter querying.
function filter(k_fn::Function, v_fn::Function, chs::ConstrainedHierarchicalSelection) where T <: Address
    top = ConstrainedHierarchicalSelection(filter(k_fn, v_fn, chs.query))
    for (k, v) in chs.tree
        top.tree[k] = filter(k_fn, v_fn, v)
    end
    isempty(top) && return ConstrainedEmptySelection()
    return top
end

# To and from arrays.
function fill_array!(val::T, arr::Vector{K}, f_ind::Int) where {K, T <: ConstrainedHierarchicalSelection}
    sorted_toplevel_keys = sort(collect(addresses(val.query)))
    sorted_tree_keys  = sort(collect(keys(val.tree)))
    idx = f_ind
    for k in sorted_toplevel_keys
        v = get_query(val, k)
        n = fill_array!(v, arr, idx)
        idx += n
    end
    for k in sorted_tree_keys
        n = fill_array!(get_sub(val, k), arr, idx)
        idx += n
    end
    idx - f_ind
end

function from_array(schema::T, arr::Vector{K}, f_ind::Int) where {K, T <: ConstrainedHierarchicalSelection}
    sel = ConstrainedHierarchicalSelection()
    sorted_toplevel_keys = sort(collect(addresses(schema.query)))
    sorted_tree_keys  = sort(collect(keys(schema.tree)))
    idx = f_ind
    for k in sorted_toplevel_keys
        (n, v) = from_array(get_query(schema, k), arr, idx)
        idx += n
        push!(sel, k, v)
    end
    for k in sorted_tree_keys
        (n, v) = from_array(get_sub(schema, k), arr, idx)
        idx += n
        sel.tree[k] = v
    end
    (idx - f_ind, sel)
end

# Used for pretty printing.
function collect!(args...) end
function collect!(par::T, addrs::Vector{Any}, chd::Dict{Any, Any}, chs::ConstrainedHierarchicalSelection) where T <: Tuple
    collect!(par, addrs, chd, chs.query)
    for (k, v) in chs.tree
        collect!((par..., k), addrs, chd, v)
    end
end
function collect!(addrs::Vector{Any}, chd::Dict{Any, Any}, chs::ConstrainedHierarchicalSelection)
    collect!(addrs, chd, chs.query)
    for (k, v) in chs.tree
        collect!((k, ), addrs, chd, v)
    end
end

function collect(chs::ConstrainedHierarchicalSelection)
    addrs = Any[]
    chd = Dict{Any, Any}()
    collect!(addrs, chd, chs)
    return addrs, chd
end

# Pretty printing.
function Base.display(chs::ConstrainedHierarchicalSelection; show_values = true)
    println("  __________________________________\n")
    println("             Constrained\n")
    addrs, chd = collect(chs)
    if show_values
        for a in addrs
            println(" $(a) = $(chd[a])")
        end
    else
        for a in addrs
            println(" $(a)")
        end
    end
    println("  __________________________________\n")
end

# ------------ CHS from vectors ----------- #

function ConstrainedHierarchicalSelection(a::Vector{Pair{K, J}}) where {K <: Tuple, J}
    top = ConstrainedHierarchicalSelection()
    for (addr, val) in a
        push!(top, addr, val)
    end
    return top
end

# ------------ CHS from traces ------------ #

function site_push!(chs::ConstrainedHierarchicalSelection, addr::Address, cs::ChoiceSite)
    push!(chs, addr, cs.val)
end
function site_push!(chs::ConstrainedHierarchicalSelection, addr::Address, cs::CallSite)
    chs.tree[addr] = get_selection(cs)
end
function push!(chs::ConstrainedHierarchicalSelection, tr::VectorizedTrace)
    for (k, cs) in enumerate(tr.subrecords)
        site_push!(chs, k, cs)
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
function get_selection(tr::VectorizedTrace)
    top = ConstrainedHierarchicalSelection()
    push!(top, tr)
    return top
end
function get_selection(tr::HierarchicalTrace)
    top = ConstrainedHierarchicalSelection()
    push!(top, tr)
    return top
end
function get_selection(cl::VectorizedCallSite)
    top = ConstrainedHierarchicalSelection()
    push!(top, cl.trace)
    return top
end
function get_selection(cl::HierarchicalCallSite)
    top = ConstrainedHierarchicalSelection()
    push!(top, cl.trace)
    return top
end

# ------------ Unconstrained selection in call hierarchy ------------ #

struct UnconstrainedHierarchicalSelection{T <: UnconstrainedSelectQuery} <: UnconstrainedSelection
    tree::Dict{Address, UnconstrainedHierarchicalSelection}
    query::T
    UnconstrainedHierarchicalSelection() = new{UnconstrainedByAddress}(Dict{Address, UnconstrainedHierarchicalSelection}(), UnconstrainedByAddress())
end
function get_sub(uhs::UnconstrainedHierarchicalSelection, addr::T) where T <: Address
    haskey(uhs.tree, addr) && return uhs.tree[addr]
    return UnconstrainedEmptySelection()
end
function get_sub(uhs::UnconstrainedHierarchicalSelection, addr::Tuple)
    isempty(addr) && return UnconstrainedEmptySelection()
    length(addr) == 1 && return get_sub(uhs, addr[1])
    haskey(uhs.tree, addr[1]) && return get_sub(uhs.tree[addr[1]], addr[2 : end])
    return UnconstrainedEmptySelection()
end
function has_query(uhs::UnconstrainedHierarchicalSelection, addr::T) where T <: Address
    has_query(uhs.query, addr)
end
function has_query(uhs::UnconstrainedHierarchicalSelection, addr::T) where T <: Tuple
    isempty(addr) && return false
    length(addr) == 1 && return has_query(uhs, addr[1])
    haskey(uhs.tree, addr[1]) && return has_query(uhs.tree[addr[1]], addr[2 : end])
    return false
end
function dump_queries(uhs::UnconstrainedHierarchicalSelection)
    toplevel = dump_queries(uhs.query)
    for (k, v) in uhs.tree
        toplevel = union(toplevel, dump_queries(v))
    end
    return toplevel
end
isempty(uhs::UnconstrainedHierarchicalSelection) = begin
    !isempty(uhs.query) && return false
    for (k, v) in uhs.tree
        !isempty(uhs.tree[k]) && return false
    end
    return true
end
function set_sub!(uhs::UnconstrainedHierarchicalSelection, addr::T, sub::K) where {T <: Address, K <: UnconstrainedSelection}
    uhs.tree[addr] = sub
end
function set_sub!(uhs::UnconstrainedHierarchicalSelection, addr::T, sub::K) where {T <: Tuple, K <: UnconstrainedSelection}
    isempty(addr) && return
    length(addr) == 1 && set_sub!(uhs, addr[1], sub)
    haskey(uhs.tree, addr[1]) && set_sub!(uhs.tree[1], addr[2 : end], sub)
end

# Used to build.
function push!(sel::UnconstrainedHierarchicalSelection, addr::T) where T <: Address
    push!(sel.query, addr)
end

function push!(sel::UnconstrainedHierarchicalSelection, addr::Int)
    push!(sel.query, addr)
end

function push!(sel::UnconstrainedHierarchicalSelection, addr::Tuple)
    fst = addr[1]
    tl = addr[2:end]
    isempty(tl) && begin
        push!(sel, fst)
        return
    end
    if !(haskey(sel.tree, fst))
        new = UnconstrainedHierarchicalSelection()
        push!(new, tl)
        sel.tree[fst] = new
    else
        sub = get_sub(sel, fst)
        push!(sub, tl)
    end
end

# ------------ UHS from vectors ------------ #

function UnconstrainedHierarchicalSelection(a::Vector{K}) where K <: Tuple
    top = UnconstrainedHierarchicalSelection()
    for addr in a
        push!(top, addr)
    end
    return top
end

# Used in functional filter querying.
function filter(k_fn::Function, chs::UnconstrainedHierarchicalSelection) where T <: Address
    top = UnconstrainedHierarchicalSelection(filter(k_fn, chs.query))
    for (k, v) in chs.tree
        top.tree[k] = filter(k_fn, v)
    end
    isempty(top) && return UnconstrainedEmptySelection()
    return top
end

# Used in pretty printing.
function collect!(par::T, addrs::Vector{Any}, chs::UnconstrainedHierarchicalSelection) where T <: Any
    collect!(par, chs.query)
    for (k, v) in chs.tree
        collect!((par..., k), addrs, v)
    end
end

function collect!(addrs::Vector{Any}, chs::UnconstrainedHierarchicalSelection)
    collect!(addrs, chs.query)
    for (k, v) in chs.tree
        collect!((k, ), addrs, v)
    end
end

function collect(chs::UnconstrainedHierarchicalSelection)
    addrs = Any[]
    collect!(addrs, chs)
    return addrs
end

# Pretty printing.
function Base.display(chs::UnconstrainedHierarchicalSelection)
    println("  __________________________________\n")
    println("              Selection\n")
    addrs = collect(chs)
    for a in addrs
        println(" $(a)")
    end
    println("  __________________________________\n")
end

