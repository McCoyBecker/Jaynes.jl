function importance_sampling(observations::K,
                             num_samples::Int,
                             model::Function, 
                             args::Tuple) where K <: AddressMap
    calls = Vector{CallSite}(undef, num_samples)
    lws = Vector{Float64}(undef, num_samples)
    Threads.@threads for i in 1:num_samples
        _, calls[i], lws[i] = generate(observations, model, args...)
    end
    ltw = lse(lws)
    lnw = lws .- ltw
    return Particles(calls, lws, 0.0), lnw
end

function importance_sampling(observations::K,
                             ps::P,
                             num_samples::Int,
                             model::Function, 
                             args::Tuple) where {K <: AddressMap, P <: AddressMap}
    calls = Vector{CallSite}(undef, num_samples)
    lws = Vector{Float64}(undef, num_samples)
    Threads.@threads for i in 1:num_samples
        _, calls[i], lws[i] = generate(observations, ps, model, args...)
    end
    ltw = lse(lws)
    lnw = lws .- ltw
    return Particles(calls, lws, 0.0), lnw
end

function importance_sampling(observations::K,
                             num_samples::Int,
                             model::Function, 
                             args::Tuple,
                             proposal::Function,
                             proposal_args::Tuple) where K <: AddressMap
    calls = Vector{CallSite}(undef, num_samples)
    lws = Vector{Float64}(undef, num_samples)
    Threads.@threads for i in 1 : num_samples
        ret, pmap, pw = propose(proposal, proposal_args...)
        overlapped = Jaynes.merge!(pmap, observations)
        overlapped && error("(importance_sampling, merge!): proposal produced a selection which overlapped with observations.")
        _, calls[i], lws[i] = generate(pmap, model, args...)
    end
    ltw = lse(lws)
    lnw = lws .- ltw
    return Particles(calls, lws, 0.0), lnw
end

function importance_sampling(observations::K,
                             ps::P,
                             num_samples::Int,
                             model::Function, 
                             args::Tuple,
                             proposal::Function,
                             proposal_args::Tuple) where {K <: AddressMap, P <: AddressMap}
    calls = Vector{CallSite}(undef, num_samples)
    lws = Vector{Float64}(undef, num_samples)
    Threads.@threads for i in 1:num_samples
        ret, pmap, pw = propose(proposal, proposal_args...)
        overlapped = merge!(pmap, observations)
        overlapped && error("(importance_sampling, merge!): proposal produced a selection which overlapped with observations.")
        _, calls[i], lws[i] = generate(pmap, ps, model, args...)
    end
    ltw = lse(lws)
    lnw = lws .- ltw
    return Particles(calls, lws, 0.0), lnw
end

function importance_sampling(observations::K,
                             num_samples::Int,
                             model::Function, 
                             args::Tuple,
                             pps::Ps,
                             proposal::Function,
                             proposal_args::Tuple) where {K <: AddressMap, Ps <: AddressMap}
    calls = Vector{CallSite}(undef, num_samples)
    lws = Vector{Float64}(undef, num_samples)
    Threads.@threads for i in 1:num_samples
        ret, pmap, pw = propose(pps, proposal, proposal_args...)
        overlapped = merge!(pmap, observations)
        overlapped && error("(importance_sampling, merge!): proposal produced a selection which overlapped with observations.")
        _, calls[i], lws[i] = generate(pmap, model, args...)
    end
    ltw = lse(lws)
    lnw = lws .- ltw
    return Particles(calls, lws, 0.0), lnw
end

function importance_sampling(observations::K,
                             ps::P,
                             num_samples::Int,
                             model::Function, 
                             args::Tuple,
                             pps::Ps,
                             proposal::Function,
                             proposal_args::Tuple) where {K <: AddressMap, P <: AddressMap, Ps <: AddressMap}
    calls = Vector{CallSite}(undef, num_samples)
    lws = Vector{Float64}(undef, num_samples)
    Threads.@threads for i in 1:num_samples
        ret, pmap, pw = propose(pps, proposal, proposal_args...)
        overlapped = merge!(pmap, observations)
        overlapped && error("(importance_sampling, merge!): proposal produced a selection which overlapped with observations.")
        _, calls[i], lws[i] = generate(pmap, ps, model, args...)
    end
    ltw = lse(lws)
    lnw = lws .- ltw
    return Particles(calls, lws, 0.0), lnw
end
