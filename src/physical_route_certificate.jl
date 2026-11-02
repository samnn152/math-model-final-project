function physical_certificate_supported(problem, mlu_cutoff)
    all(v == 1.0 for matrix in problem.ratios for v in nonzeros(matrix)) || return false
    problem.temporal || return true
    failure = certificate_failure_coupling(problem)
    return failure.valid && all(problem.volumes[d, 1] / problem.data.c[a] > mlu_cutoff
        for d in 1:problem.D for a in failure.affected)
end

function build_physical_certificate(problem, initial_paths; solver=:highs, seed=1,
        threads=1, time_limit=60.0, mlu_cutoff=Inf, max_variables=2_000_000, compact_lex=false, sr_refinement=:segment)
    sr_refinement in (:segment, :layered) || error("Unknown exact SR refinement")
    physical_certificate_supported(problem, mlu_cutoff) || error("Physical certificate assumptions do not hold")
    problem.D * problem.m + problem.M + 1 + (compact_lex ? problem.M + 1 : 0) <= max_variables ||
        error("MODEL_SIZE_LIMIT: physical certificate")
    model = create_time0_optimizer(solver; time_limit, seed, threads)
    set_string_names_on_creation(model, false)
    if solver == :highs
        for name in ("primal_feasibility_tolerance", "dual_feasibility_tolerance", "mip_feasibility_tolerance")
            set_optimizer_attribute(model, name, 1e-9)
        end
    else
        set_optimizer_attribute(model, "numerics/feastol", 1e-9)
    end
    g = @variable(model, [1:problem.D, 1:problem.m], binary=true)
    loads = @variable(model, [1:problem.M], lower_bound=0.0)
    z = @variable(model, lower_bound=0.0)
    isfinite(mlu_cutoff) && set_upper_bound(z, mlu_cutoff)
    outgoing = [[a for (a, (i, j)) in enumerate(problem.data.arcs) if i == v] for v in 1:problem.n]
    incoming = [[a for (a, (i, j)) in enumerate(problem.data.arcs) if j == v] for v in 1:problem.n]
    for d in 1:problem.D, v in 1:problem.n
        @constraint(model, sum(g[d, a] for a in outgoing[v]) - sum(g[d, a] for a in incoming[v]) ==
            (v == problem.sources[d] ? 1 : v == problem.targets[d] ? -1 : 0))
        @constraint(model, sum(g[d, a] for a in outgoing[v]) <= 1)
        @constraint(model, sum(g[d, a] for a in incoming[v]) <= 1)
    end
    supported = [vec(sum(matrix; dims=2)) .> 0.0 for matrix in problem.ratios]
    for d in 1:problem.D, a in 1:problem.m
        i, j = problem.data.arcs[a]
        forbidden = any(!supported[t][a] || problem.volumes[d, t] / problem.data.c[a] > mlu_cutoff
            for t in eachindex(problem.ratios))
        if forbidden || j == problem.sources[d] || i == problem.targets[d]
            fix(g[d, a], 0.0; force=true)
        end
    end
    load_rows = ConstraintRef[]
    load_scales = repeat(problem.data.c, length(problem.ratios))
    for t in eachindex(problem.ratios), a in 1:problem.m
        # Positive capacity scaling preserves the original normalized load inequality.
        push!(load_rows, @constraint(model,
            sum(problem.volumes[d, t] * g[d, a] for d in 1:problem.D) <=
            problem.data.c[a] * loads[(t - 1) * problem.m + a]))
    end
    @constraint(model, [a in 1:problem.M], loads[a] <= z)
    lex_threshold = compact_lex ? @variable(model, lower_bound=0.0) : nothing
    lex_excess = compact_lex ? @variable(model, [1:problem.M], lower_bound=0.0) : nothing
    if compact_lex
        @constraint(model, [a in 1:problem.M], lex_excess[a] >= loads[a] - lex_threshold)
    end
    problem.temporal && @constraint(model, AffExpr(0.0) <= problem.data.budget)
    physical_middle = Dict((d, t) => [g[d, a] for a in 1:problem.m]
        for d in 1:problem.D for t in eachindex(problem.ratios))
    affected = problem.temporal ? certificate_failure_coupling(problem).affected : Int[]
    return (; model, g, loads, z, load_rows, load_scales, mlu_cutoff,
        kind=:physical, initial_paths=deepcopy(initial_paths), physical_middle, compact_lex, sr_refinement,
        lex_threshold, lex_excess,
        lex_cut_keys=Dict{Int,Set{Tuple}}(), transient_rows=ConstraintRef[],
        physical_change_flags=Dict(), physical_affected_arcs=affected,
        middle_flow_mode=problem.temporal ? "shared_whole_physical_path_cutoff" : "whole_physical_path",
        refined=Dict{Int,Any}(), stages=NamedTuple[])
end

function physical_certificate_projection(problem, d, path)
    used = Int[]
    matrix = problem.ratios[1]
    for (i, j) in zip(path, path[2:end])
        column = i + (j - 1) * problem.n
        append!(used, [rowvals(matrix)[h] for h in nzrange(matrix, column)])
    end
    return certificate_physical_path(problem, used, problem.sources[d], problem.targets[d])
end

function refine_physical_certificate_demand!(master, problem, d; max_variables=2_000_000)
    master.sr_refinement == :layered && return refine_layered_sr_demand!(master, problem, d; max_variables)
    haskey(master.refined, d) && return false
    edges = [(i, j) for j in 1:problem.n for i in 1:problem.n if problem.reachable[i, j]]
    num_variables(master.model) + length(edges) + problem.n <= max_variables ||
        error("MODEL_SIZE_LIMIT: physical-to-SR refinement")
    detach_physical_certificate_demand!(master, problem, d)
    x = Dict{Tuple{Int,Int},VariableRef}()
    for (i, j) in edges
        variable = @variable(master.model, binary=true)
        x[i, j] = variable
        coefficients = certificate_segment_coefficients(problem, d, i, j)
        maximum(coefficients; init=0.0) > master.mlu_cutoff && fix(variable, 0.0; force=true)
        rows, coefficient_values = findnz(coefficients)
        for h in eachindex(rows)
            set_normalized_coefficient(master.load_rows[rows[h]], variable, coefficient_values[h] * master.load_scales[rows[h]])
        end
    end
    for v in 1:problem.n
        outgoing = [variable for ((i, j), variable) in x if i == v]
        incoming = [variable for ((i, j), variable) in x if j == v]
        @constraint(master.model, sum(outgoing) - sum(incoming) ==
            (v == problem.sources[d] ? 1 : v == problem.targets[d] ? -1 : 0))
        @constraint(master.model, sum(outgoing) <= 1)
        @constraint(master.model, sum(incoming) <= 1)
    end
    @constraint(master.model, sum(values(x)) <= problem.K)
    position = certificate_path_positions!(master.model, problem, d, x)
    master.refined[d] = (; x, position, integer=true, formulation=:segment)
    return true
end

function detach_physical_certificate_demand!(master, problem, d)
    dummy = physical_certificate_projection(problem, d, master.initial_paths[d])
    isempty(dummy) && error("No physical projection of a validated initial route")
    arc_index = Dict(edge => a for (a, edge) in enumerate(problem.data.arcs))
    selected = Set(arc_index[edge] for edge in zip(dummy, dummy[2:end]))
    for a in 1:problem.m
        fix(master.g[d, a], a in selected ? 1.0 : 0.0; force=true)
        for t in eachindex(problem.ratios)
            set_normalized_coefficient(master.load_rows[(t - 1) * problem.m + a], master.g[d, a], 0.0)
        end
    end
    return nothing
end

function physical_certificate_candidate_paths(master, problem)
    paths = Vector{Int}[]
    offending = Int[]
    for d in 1:problem.D
        if haskey(master.refined, d)
            if master.refined[d].formulation == :layered
                push!(paths, layered_sr_candidate(master.refined[d], problem, d))
                continue
            end
            x = master.refined[d].x
            path = Int[problem.sources[d]]
            while last(path) != problem.targets[d]
                next = only([j for ((i, j), variable) in x if i == last(path) && value(variable) > 0.5])
                next in path && error("Cycle in exact SR refinement")
                push!(path, next)
            end
        else
            physical = certificate_physical_path(problem,
                findall(a -> value(master.g[d, a]) > 0.5, 1:problem.m),
                problem.sources[d], problem.targets[d])
            isempty(physical) && error("Physical flow has no source-target path")
            path = compress_certificate_physical_path(problem, 1, physical)
            isempty(path) && error("Supported physical path could not be compressed")
            length(path) - 1 > problem.K && push!(offending, d)
        end
        push!(paths, path)
    end
    return (; paths, offending)
end

function warm_physical_certificate!(master, problem, validation)
    arc_index = Dict(edge => a for (a, edge) in enumerate(problem.data.arcs))
    for d in 1:problem.D
        physical = physical_certificate_projection(problem, d, validation.paths[d])
        selected = Set(arc_index[edge] for edge in zip(physical, physical[2:end]))
        for a in 1:problem.m
            variable = master.g[d, a]
            set_start_value(variable, is_fixed(variable) ? fix_value(variable) : a in selected ? 1.0 : 0.0)
        end
        if haskey(master.refined, d)
            path = validation.paths[d]
            if master.refined[d].formulation == :layered
                warm_layered_sr!(master.refined[d], problem, path)
                continue
            end
            edges = Set(zip(path, path[2:end]))
            for (edge, variable) in master.refined[d].x
                set_start_value(variable, is_fixed(variable) ? fix_value(variable) : edge in edges ? 1.0 : 0.0)
            end
            for i in 1:problem.n
                at = findfirst(==(i), path)
                set_start_value(master.refined[d].position[i], isnothing(at) ? 0.0 : at - 1.0)
            end
        end
    end
    vector = sort(validation.loads; rev=true)
    if master.compact_lex
        set_start_value(master.lex_threshold, first(vector))
        for variable in master.lex_excess
            set_start_value(variable, 0.0)
        end
    end
    for a in 1:problem.M
        set_start_value(master.loads[a], validation.loads[a])
    end
    set_start_value(master.z, maximum(validation.loads))
    for stage in master.stages
        isnothing(stage.threshold) && continue
        set_start_value(stage.threshold, vector[stage.k])
        for a in 1:problem.M
            set_start_value(stage.excess[a], max(0.0, validation.loads[a] - vector[stage.k]))
        end
    end
    return nothing
end
