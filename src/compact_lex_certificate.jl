function add_certificate_lex_stage!(master, k, M)
    master.compact_lex || return add_lexicographic_stage!(master, k, M)
    model = master.model
    if k == 1 || k == M
        expression = k == 1 ? 1.0 * master.z : sum(master.loads)
        @objective(model, Min, expression)
        return (; k, expression, threshold=nothing, excess=nothing, rows=ConstraintRef[])
    end
    threshold = master.lex_threshold
    excess = master.lex_excess
    expression = k * threshold + sum(excess)
    @objective(model, Min, expression)
    return (; k, expression, threshold, excess, rows=ConstraintRef[])
end

function clear_compact_certificate_stage!(master)
    master.compact_lex || return nothing
    isempty(master.stages) && return nothing
    @objective(master.model, Min, 0.0)
    isempty(master.transient_rows) || delete(master.model, master.transient_rows)
    empty!(master.transient_rows)
    empty!(master.stages)
    return nothing
end

function add_compact_lex_upper!(master, k, indices, upper)
    master.compact_lex || error("Subset lock requires compact lexicographic mode")
    length(indices) == k && length(unique(indices)) == k || error("Invalid top-k subset")
    all(1 <= a <= length(master.loads) for a in indices) || error("Invalid load index")
    if k == 1
        current = has_upper_bound(master.z) ? upper_bound(master.z) : Inf
        set_upper_bound(master.z, min(current, upper))
        return false
    end
    key = Tuple(sort(collect(indices)))
    known = get!(master.lex_cut_keys, k, Set{Tuple}())
    key in known && return false
    @constraint(master.model, sum(master.loads[a] for a in key) <= upper)
    push!(known, key)
    return true
end

function compact_lex_violations(master, locks, loads)
    master.compact_lex || return Int[]
    cumulative = cumsum(sort(loads; rev=true))
    return [j for j in eachindex(locks) if cumulative[j] > locks[j] + 1e-8]
end

function separate_compact_lex_locks!(master, locks, loads)
    master.compact_lex || return 0
    order = sortperm(loads; rev=true)
    added = 0
    for j in compact_lex_violations(master, locks, loads)
        added += add_compact_lex_upper!(master, j, order[1:j], locks[j])
    end
    return added
end

function compact_lex_snapshot(master)
    master.compact_lex || return nothing
    return Dict(string(k) => [collect(key) for key in sort(collect(keys))]
        for (k, keys) in master.lex_cut_keys)
end
