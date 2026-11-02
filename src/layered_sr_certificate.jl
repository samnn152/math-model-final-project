function refine_layered_sr_demand!(master, problem, d; max_variables=2_000_000)
    haskey(master.refined, d) && return false
    source, target = problem.sources[d], problem.targets[d]
    coefficients = Dict{Tuple{Int,Int},SparseVector{Float64,Int}}()
    for j in 1:problem.n, i in 1:problem.n
        problem.reachable[i, j] && i != target && j != source || continue
        column = certificate_segment_coefficients(problem, d, i, j)
        maximum(column; init=0.0) <= master.mlu_cutoff || continue
        coefficients[i, j] = column
    end
    keys = Tuple{Int,Int,Int}[]
    for h in 0:problem.K-1, i in 1:problem.n, j in 1:problem.n
        h == 0 && i != source && continue
        h == problem.K-1 && j != target && continue
        if (i == target && j == target) || haskey(coefficients, (i, j))
            push!(keys, (h, i, j))
        end
    end
    num_variables(master.model) + (problem.K+1)*problem.n + length(keys) <= max_variables ||
        error("MODEL_SIZE_LIMIT: layered exact SR refinement")
    detach_physical_certificate_demand!(master, problem, d)
    model = master.model
    node = @variable(model, [0:problem.K, 1:problem.n], binary=true)
    for i in 1:problem.n
        fix(node[0, i], i == source ? 1.0 : 0.0; force=true)
        fix(node[problem.K, i], i == target ? 1.0 : 0.0; force=true)
    end
    for h in 1:problem.K
        fix(node[h, source], 0.0; force=true)
    end
    @constraint(model, [h in 0:problem.K], sum(node[h, i] for i in 1:problem.n) == 1)
    for i in 1:problem.n
        i == target && continue
        @constraint(model, sum(node[h, i] for h in 0:problem.K) <= 1)
    end
    outgoing = [VariableRef[] for h in 1:problem.K, i in 1:problem.n]
    incoming = [VariableRef[] for h in 1:problem.K, i in 1:problem.n]
    transitions = Dict{Tuple{Int,Int,Int},VariableRef}()
    for (h, i, j) in keys
        variable = @variable(model, lower_bound=0.0, upper_bound=1.0)
        transitions[h, i, j] = variable
        push!(outgoing[h+1, i], variable)
        push!(incoming[h+1, j], variable)
        i == j && continue
        rows, values = findnz(coefficients[i, j])
        for a in eachindex(rows)
            set_normalized_coefficient(master.load_rows[rows[a]], variable,
                values[a] * master.load_scales[rows[a]])
        end
    end
    for h in 0:problem.K-1, i in 1:problem.n
        @constraint(model, sum(outgoing[h+1, i]) == node[h, i])
        @constraint(model, sum(incoming[h+1, i]) == node[h+1, i])
    end
    @constraint(model, sum(variable for ((h, i, j), variable) in transitions if i != j) <= problem.K)
    master.refined[d] = (; formulation=:layered, node, transitions, integer=true)
    return true
end

function layered_sr_candidate(refinement, problem, d)
    path = Int[problem.sources[d]]
    for h in 1:problem.K
        last(path) == problem.targets[d] && break
        next = only([i for i in 1:problem.n if value(refinement.node[h, i]) > 0.5])
        next in path && error("Repeated waypoint in layered SR refinement")
        push!(path, next)
    end
    last(path) == problem.targets[d] || error("Layered SR route misses its target")
    return path
end

function warm_layered_sr!(refinement, problem, path)
    sequence = [path[min(h+1, length(path))] for h in 0:problem.K]
    for h in 0:problem.K, i in 1:problem.n
        set_start_value(refinement.node[h, i], i == sequence[h+1] ? 1.0 : 0.0)
    end
    for ((h, i, j), variable) in refinement.transitions
        set_start_value(variable, i == sequence[h+1] && j == sequence[h+2] ? 1.0 : 0.0)
    end
    return nothing
end
