import SHA

function certificate_problem(data;temporal=false)
    temporal && !(0<=data.budget<=1) && error("Common-route certificate requires 0 <= Budget <= 1")
    periods=temporal ? data.periods : (data,)
    n=length(data.node_ids);m=length(data.arcs);D=length(data.sources)
    ratios=[sparse(transpose(p.r.values)) for p in periods]
    reachable=reduce(.&, [p.counts.>0 for p in periods])
    for i in 1:n;reachable[i,i]=false;end
    volumes=temporal ? [data.v[d,t-1] for d in 1:D,t in 1:2] : reshape(copy(data.v),D,1)
    return (;data,temporal,n,m,D,M=m*length(periods),K=data.MaxSeg,ratios,reachable,volumes,
        sources=data.sources,targets=data.targets)
end

function certificate_data_signature(problem)
    payload=(;problem.temporal,problem.n,problem.m,problem.D,problem.K,
        problem.sources,problem.targets,problem.volumes,problem.reachable,
        nodes=problem.data.node_ids,demands=problem.data.demand_ids,arcs=problem.data.arcs,
        capacity=problem.data.c,budget=problem.temporal ? problem.data.budget : nothing,
        routing=[(;columns=p.colptr,rows=rowvals(p),values=nonzeros(p)) for p in problem.ratios])
    return bytes2hex(SHA.sha256(JSON3.write(payload)))
end

function certificate_node_count(model,solver)
    return solver==:scip ? Int(SCIP.SCIPgetNTotalNodes(unsafe_backend(model))) : node_count(model)
end

certificate_exact_demand_indices(master)=sort([d for (d,refinement) in master.refined if refinement.integer])

function certificate_segment_coefficients(problem,d,i,j)
    indices=Int[];values=Float64[];col=i+(j-1)*problem.n
    for t in eachindex(problem.ratios)
        matrix=problem.ratios[t];rows=rowvals(matrix);entries=nonzeros(matrix)
        for h in nzrange(matrix,col)
            a=rows[h];push!(indices,(t-1)*problem.m+a)
            push!(values,problem.volumes[d,t]*entries[h]/problem.data.c[a])
        end
    end
    return sparsevec(indices,values,problem.M)
end

function certificate_add_coefficients!(expressions,variable,coefficients)
    indices,values=findnz(coefficients)
    for h in eachindex(indices);add_to_expression!(expressions[indices[h]],values[h],variable);end
end

function build_endpoint_certificate(problem;solver=:highs,seed=1,threads=1,time_limit=60.,middle_flow=:auto,mlu_cutoff=Inf)
    D,n,M=problem.D,problem.n,problem.M
    deterministic=all(v==1. for matrix in problem.ratios for v in nonzeros(matrix))
    middle_flow===:integer && !deterministic && error("Integer physical certificate requires deterministic routing in every period")
    model=create_time0_optimizer(solver;time_limit,seed,threads)
    set_string_names_on_creation(model,false)
    if solver==:highs
        for name in ("primal_feasibility_tolerance","dual_feasibility_tolerance","mip_feasibility_tolerance")
            set_optimizer_attribute(model,name,1e-9)
        end
    elseif solver==:scip
        set_optimizer_attribute(model,"numerics/feastol",1e-9)
    end
    direct=@variable(model,[1:D],binary=true)
    first_leg=@variable(model,[1:D,1:n],binary=true)
    last_leg=@variable(model,[1:D,1:n],binary=true)
    loads=@variable(model,[1:M],lower_bound=0.);z=@variable(model,lower_bound=0.)
    isfinite(mlu_cutoff) && @constraint(model,z<=mlu_cutoff)
    expressions=[AffExpr(0.) for a in 1:M]
    for d in 1:D
        s,t=problem.sources[d],problem.targets[d]
        problem.reachable[s,t] || fix(direct[d],0.;force=true)
        direct_coefficients=certificate_segment_coefficients(problem,d,s,t)
        maximum(direct_coefficients;init=0.)>mlu_cutoff && fix(direct[d],0.;force=true)
        certificate_add_coefficients!(expressions,direct[d],direct_coefficients)
        for i in 1:n
            if i in (s,t) || problem.K<2
                fix(first_leg[d,i],0.;force=true);fix(last_leg[d,i],0.;force=true);continue
            end
            problem.reachable[s,i] || fix(first_leg[d,i],0.;force=true)
            problem.reachable[i,t] || fix(last_leg[d,i],0.;force=true)
            first_coefficients=certificate_segment_coefficients(problem,d,s,i)
            last_coefficients=certificate_segment_coefficients(problem,d,i,t)
            maximum(first_coefficients;init=0.)>mlu_cutoff && fix(first_leg[d,i],0.;force=true)
            maximum(last_coefficients;init=0.)>mlu_cutoff && fix(last_leg[d,i],0.;force=true)
            certificate_add_coefficients!(expressions,first_leg[d,i],first_coefficients)
            certificate_add_coefficients!(expressions,last_leg[d,i],last_coefficients)
        end
        @constraint(model,direct[d]+sum(first_leg[d,:])==1)
        @constraint(model,direct[d]+sum(last_leg[d,:])==1)
    end
    load_rows=[@constraint(model,expressions[a]<=loads[a]) for a in 1:M]
    @constraint(model,[a in 1:M],loads[a]<=z)
    problem.temporal && @constraint(model,AffExpr(0.)<=problem.data.budget)
    master=(;model,direct,first_leg,last_leg,loads,z,load_rows,mlu_cutoff,kind=:endpoint,compact_lex=false,
        refined=Dict{Int,Any}(),stages=NamedTuple[])
    mode=middle_flow===:auto ? (deterministic ? :integer : false) : middle_flow
    physical=mode===false ? (flows=Dict(),flags=Dict(),affected=Int[],mode="none") :
        add_certificate_middle_flow!(master,problem,expressions;integer=mode===:integer)
    return merge(master,(;physical_middle=physical.flows,physical_change_flags=physical.flags,
        physical_affected_arcs=physical.affected,middle_flow_mode=physical.mode))
end

function certificate_failure_coupling(problem)
    problem.temporal || return (;valid=false,affected=Int[])
    affected=[a for (a,(i,j)) in enumerate(problem.data.arcs) if !has_edge(problem.data.periods[2].graph,i,j)]
    failed=Set(affected)
    left,right=problem.ratios
    for j in 1:problem.n,i in 1:problem.n
        problem.reachable[i,j] || continue
        column=i+(j-1)*problem.n
        rows0=[rowvals(left)[h] for h in nzrange(left,column)]
        any(a in failed for a in rows0) && continue
        rows1=[rowvals(right)[h] for h in nzrange(right,column)]
        rows0==rows1 || return (;valid=false,affected)
    end
    return (;valid=true,affected)
end

function add_certificate_middle_flow!(master,problem,endpoint_expressions;integer=false)
    integer && !all(v==1. for matrix in problem.ratios for v in nonzeros(matrix)) &&
        error("Integer physical certificate requires deterministic routing in every period")
    failure=integer ? certificate_failure_coupling(problem) : (valid=false,affected=Int[])
    coupled=integer && failure.valid
    shared=coupled && all(problem.volumes[d,1]/problem.data.c[a]>master.mlu_cutoff
        for d in 1:problem.D for a in failure.affected)
    limit=max(0,problem.K-2)
    model=master.model;n=problem.n;m=problem.m
    outgoing=[[a for (a,(i,j)) in enumerate(problem.data.arcs) if i==v] for v in 1:n]
    incoming=[[a for (a,(i,j)) in enumerate(problem.data.arcs) if j==v] for v in 1:n]
    physical=copy.(endpoint_expressions)
    flows=Dict{Tuple{Int,Int},Vector{VariableRef}}()
    supported_by_period=[vec(sum(matrix;dims=2)).>0. for matrix in problem.ratios]
    for t in eachindex(problem.ratios),d in 1:problem.D
        middle=if shared && t==2
            flows[d,1]
        elseif coupled && !shared
            @variable(model,[1:m],lower_bound=0.,upper_bound=limit,integer=true)
        else
            @variable(model,[1:m],lower_bound=0.,binary=integer)
        end
        flows[d,t]=middle
        period=problem.temporal ? problem.data.periods[t] : problem.data
        supported=supported_by_period[t]
        for (a,(i,j)) in enumerate(problem.data.arcs)
            has_edge(period.graph,i,j) && supported[a] || fix(middle[a],0.;force=true)
            integer && problem.volumes[d,t]/problem.data.c[a]>master.mlu_cutoff && fix(middle[a],0.;force=true)
        end
        if !(shared && t==2)
            for v in 1:n
                @constraint(model,sum(middle[a] for a in outgoing[v])-sum(middle[a] for a in incoming[v])==
                    master.first_leg[d,v]-master.last_leg[d,v])
                if integer
                    @constraint(model,sum(middle[a] for a in outgoing[v])<=(coupled && !shared ? limit : 1))
                    @constraint(model,sum(middle[a] for a in incoming[v])<=(coupled && !shared ? limit : 1))
                end
            end
            integer && @constraint(model,sum(middle)<=limit*(n-1)*(1-master.direct[d]))
        end
        for a in 1:m
            add_to_expression!(physical[(t-1)*m+a],problem.volumes[d,t]/problem.data.c[a],middle[a])
        end
    end
    flags=Dict{Int,VariableRef}()
    if coupled && !shared
        for d in 1:problem.D
            flag=@variable(model,binary=true);flags[d]=flag
            changed=sum(flows[d,1][a] for a in failure.affected;init=AffExpr(0.))
            @constraint(model,changed<=limit*length(failure.affected)*flag)
            @constraint(model,flag<=changed)
            for a in 1:m
                @constraint(model,flows[d,2][a]-flows[d,1][a]<=limit*flag)
                @constraint(model,flows[d,1][a]-flows[d,2][a]<=limit*flag)
            end
        end
    end
    @constraint(model,[a in 1:problem.M],physical[a]<=master.loads[a])
    return (;flows,flags,affected=failure.affected,
        mode=shared ? "shared_binary_deterministic_cutoff" : coupled ? "coupled_integer_deterministic" : integer ? "binary_deterministic" : "continuous")
end

function refine_certificate_demand!(master,problem,d;max_variables=2_000_000,integer=true)
    master.kind==:physical && return refine_physical_certificate_demand!(master,problem,d;max_variables)
    if haskey(master.refined,d)
        (master.refined[d].integer || !integer) && return false
        num_variables(master.model)+problem.n<=max_variables || error("MODEL_SIZE_LIMIT: integer promotion")
        x=master.refined[d].x
        for variable in values(x);is_binary(variable) || set_binary(variable);end
        position=certificate_path_positions!(master.model,problem,d,x)
        master.refined[d]=(;x,position,integer=true)
        return true
    end
    n=problem.n;s,t=problem.sources[d],problem.targets[d]
    edges=[(i,j) for j in 1:n for i in 1:n if problem.reachable[i,j]]
    num_variables(master.model)+length(edges)+n<=max_variables || error("MODEL_SIZE_LIMIT: exact demand refinement")
    model=master.model;x=Dict{Tuple{Int,Int},VariableRef}()
    for (i,j) in edges
        variable=if i==s && j==t
            master.direct[d]
        elseif i==s
            master.first_leg[d,j]
        elseif j==t
            master.last_leg[d,i]
        else
            @variable(model,lower_bound=0.,upper_bound=1.,binary=integer)
        end
        x[i,j]=variable
        if i!=s && j!=t
            coefficients=certificate_segment_coefficients(problem,d,i,j)
            indices,coeff_values=findnz(coefficients)
            for h in eachindex(indices)
                set_normalized_coefficient(master.load_rows[indices[h]],variable,coeff_values[h])
            end
        end
    end
    for node in 1:n
        outgoing=[v for ((i,j),v) in x if i==node]
        incoming=[v for ((i,j),v) in x if j==node]
        @constraint(model,sum(outgoing)-sum(incoming)==(node==s ? 1 : node==t ? -1 : 0))
        @constraint(model,sum(outgoing)<=1)
        @constraint(model,sum(incoming)<=1)
    end
    @constraint(model,sum(values(x))<=problem.K)
    position=integer ? certificate_path_positions!(model,problem,d,x) : nothing
    master.refined[d]=(;x,position,integer)
    return true
end

function certificate_path_positions!(model,problem,d,x)
    position=@variable(model,[1:problem.n],lower_bound=0.,upper_bound=problem.K)
    fix(position[problem.sources[d]],0.;force=true)
    for ((i,j),variable) in x
        @constraint(model,position[j]>=position[i]+1-(problem.K+1)*(1-variable))
    end
    return position
end

function certificate_candidate_paths(master,problem)
    master.kind==:physical && return physical_certificate_candidate_paths(master,problem)
    paths=Vector{Int}[];offending=Int[]
    for d in 1:problem.D
        s,t=problem.sources[d],problem.targets[d]
        if haskey(master.refined,d) && master.refined[d].integer
            x=master.refined[d].x;path=Int[s]
            while last(path)!=t
                next=[j for ((i,j),v) in x if i==last(path) && value(v)>.5]
                length(next)==1 || error("Invalid refined path")
                only(next) in path && error("Refined path cycle")
                push!(path,only(next))
                length(path)<=problem.K+1 || error("Refined MaxSeg violation")
            end
        elseif value(master.direct[d])>.5
            path=Int[s,t]
        else
            first_node=only([i for i in 1:problem.n if value(master.first_leg[d,i])>.5])
            last_node=only([i for i in 1:problem.n if value(master.last_leg[d,i])>.5])
            path=first_node==last_node ? Int[s,first_node,t] : Int[s,first_node,last_node,t]
            first_node!=last_node && push!(offending,d)
        end
        push!(paths,path)
    end
    return (;paths,offending)
end

function prioritize_certificate_refinements(master,problem,candidate,k)
    master.kind==:physical && return sort(candidate.offending;by=d->(-length(candidate.paths[d]),d))
    actual_loads=zeros(problem.M)
    for d in 1:problem.D,(i,j) in zip(candidate.paths[d],candidate.paths[d][2:end])
        actual_loads+=certificate_segment_coefficients(problem,d,i,j)
    end
    weights=zeros(problem.M)
    for (rank,a) in enumerate(sortperm(actual_loads;rev=true)[1:k])
        weights[a]=k-rank+1
    end
    scores=Dict(d=>sum(weights.*certificate_segment_coefficients(problem,d,candidate.paths[d][2],candidate.paths[d][end-1])) for d in candidate.offending)
    return sort(candidate.offending;by=d->(haskey(master.refined,d),-scores[d],d))
end

function validate_certificate_paths(problem,paths)
    all(length(p)-1<=problem.K && length(unique(p))==length(p) &&
        all(problem.reachable[i,j] for (i,j) in zip(p,p[2:end])) for p in paths) || return nothing
    if problem.temporal
        columns=NamedTuple[];keys=[Set{Tuple}() for d in 1:problem.D]
        selection=[add_time01_pair!(columns,keys,problem.data,d,paths[d],paths[d]) for d in 1:problem.D]
        validation=validate_time01_pairs(problem.data,columns,selection)
        return (;loads=validation.loads,paths,srpaths=validation.srpaths,budget_used=validation.cost)
    end
    pool=initial_route_pool(problem.data);selection=Int[]
    for d in 1:problem.D
        p=add_route_column!(pool,problem.data,d,paths[d];max_routes=2)
        p==0 && (p=only(pool.by_demand[d]))
        push!(selection,p)
    end
    validation=validate_route_selection(problem.data,pool,selection)
    return (;loads=validation.arc_loads,paths,srpaths=validation.routes,budget_used=0)
end

function certificate_candidate_improves(actual,incumbent,k,locks)
    vector=sort(actual.loads;rev=true);previous=sort(incumbent.loads;rev=true)
    all(sum(vector[1:j])<=locks[j]+1e-8 for j in eachindex(locks)) || return false
    upper=sum(vector[1:k]);old_upper=sum(previous[1:k])
    return upper<old_upper-1e-10 ||
        (upper<=old_upper+1e-10 && lex_loads_improve(vector,previous;tolerance=1e-10))
end

function warm_certificate!(master,problem,validation)
    master.kind==:physical && return warm_physical_certificate!(master,problem,validation)
    arc_index=Dict(edge=>a for (a,edge) in enumerate(problem.data.arcs))
    for ((d,t),variables) in master.physical_middle
        path=validation.paths[d];used=Int[]
        amounts=zeros(problem.m)
        for (i,j) in zip(path[2:end-1],path[3:end-1])
            matrix=problem.ratios[t];column=i+(j-1)*problem.n
            append!(used,[rowvals(matrix)[h] for h in nzrange(matrix,column)])
            for h in nzrange(matrix,column);amounts[rowvals(matrix)[h]]+=nonzeros(matrix)[h];end
        end
        if !is_binary(first(variables))
            for (a,v) in enumerate(variables);set_start_value(v,amounts[a]);end
            continue
        end
        middle=length(path)>2 ? certificate_physical_path(problem,used,path[2],path[end-1]) : Int[]
        selected=Set(arc_index[edge] for edge in zip(middle,middle[2:end]))
        for (a,v) in enumerate(variables);set_start_value(v,a in selected ? 1. : 0.);end
    end
    for (d,flag) in master.physical_change_flags
        affected=any(start_value(master.physical_middle[d,1][a])>.5 for a in master.physical_affected_arcs)
        set_start_value(flag,affected ? 1. : 0.)
    end
    for d in 1:problem.D
        path=validation.paths[d]
        set_start_value(master.direct[d],length(path)==2 ? 1. : 0.)
        for i in 1:problem.n
            set_start_value(master.first_leg[d,i],length(path)>2 && path[2]==i ? 1. : 0.)
            set_start_value(master.last_leg[d,i],length(path)>2 && path[end-1]==i ? 1. : 0.)
        end
        if haskey(master.refined,d)
            edges=Set(zip(path,path[2:end]))
            for (edge,v) in master.refined[d].x;set_start_value(v,edge in edges ? 1. : 0.);end
            if master.refined[d].integer
                for i in 1:problem.n
                    at=findfirst(==(i),path)
                    set_start_value(master.refined[d].position[i],isnothing(at) ? 0. : at-1.)
                end
            end
        end
    end
    for a in 1:problem.M;set_start_value(master.loads[a],validation.loads[a]);end
    set_start_value(master.z,maximum(validation.loads))
    vector=sort(validation.loads;rev=true)
    for stage in master.stages
        isnothing(stage.threshold) && continue
        set_start_value(stage.threshold,vector[stage.k])
        for a in 1:problem.M;set_start_value(stage.excess[a],max(0.,validation.loads[a]-vector[stage.k]));end
    end
end

function load_certificate_incumbent(problem,path)
    paths=[Int[problem.sources[d],problem.targets[d]] for d in 1:problem.D]
    if !isempty(path) && isfile(path)
        saved=JSON3.read(read(path,String));index=Dict(id=>i for (i,id) in enumerate(problem.data.node_ids))
        for row in saved.srpaths
            Int(row.t)==0 || continue
            d=findfirst(==(Int(row.d)),problem.data.demand_ids)
            paths[d]=vcat(problem.sources[d],[index[Int(id)] for id in row.w],problem.targets[d])
        end
    end
    validation=validate_certificate_paths(problem,paths)
    validation===nothing && error("Initial route is not valid in the certificate domain")
    return validation
end

function install_complete_certificate_scip_start!(model)
    optimizer=unsafe_backend(model)
    solution=Ref{Ptr{SCIP.SCIP_SOL}}(C_NULL)
    SCIP.@SCIP_CALL SCIP.SCIPcreateOrigSol(optimizer,solution,C_NULL)
    try
        for variable in all_variables(model)
            initial=start_value(variable)
            isnothing(initial) && error("Certificate SCIP warm start is incomplete")
            SCIP.@SCIP_CALL SCIP.SCIPsetSolVal(optimizer,solution[],SCIP.var(optimizer,index(variable)),initial)
            set_start_value(variable,nothing)
        end
        stored=Ref{SCIP.SCIP_Bool}(SCIP.FALSE)
        SCIP.@SCIP_CALL SCIP.SCIPaddSolFree(optimizer,solution,stored)
    finally
        solution[]==C_NULL || SCIP.@SCIP_CALL SCIP.SCIPfreeSol(optimizer,solution)
    end
    return nothing
end

function solve_adaptive_integer_certificate(data;temporal=false,time_limit=1800.,seed=1001,threads=1,solver=:highs,
        incumbent_file="",output_prefix="",proof_tolerance=1e-7,lock_tolerance=1e-7,
        max_variables=2_000_000,refinement_batch=4,resume_checkpoint="",compact_lex=false,sr_refinement=:segment)
    started=time()
    problem=certificate_problem(data;temporal)
    data_signature=certificate_data_signature(problem)
    resumed=isempty(resume_checkpoint) ? nothing : JSON3.read(read(resume_checkpoint,String))
    if resumed!==nothing
        resumed.data_signature==data_signature || error("Certificate resume: different original problem")
        resumed.proof_tolerance==proof_tolerance && resumed.lock_tolerance==lock_tolerance ||
            error("Certificate resume: different proof tolerances")
        length(resumed.certified_top_k_locks)==resumed.lex_completed_stages || error("Certificate resume: missing locks")
        incumbent_file=resume_checkpoint
    end
    validation=load_certificate_incumbent(problem,incumbent_file)
    route_pool=initial_certificate_route_pool(problem,validation)
    elapsed=0.;completed=0;locks=Float64[];nodes=0;first_bound=0.;stage_bound=0.;termination="TIME_LIMIT"
    state=nothing
    prior_diagnostic_seconds=0.
    if resumed!==nothing
        completed=Int(resumed.lex_completed_stages);locks=Float64.(resumed.certified_top_k_locks)
        0<=completed<=problem.M || error("Certificate resume: invalid prefix length")
        vector=sort(validation.loads;rev=true)
        all(sum(vector[1:j])<=locks[j]+1e-8 for j in eachindex(locks)) || error("Certificate resume: route violates certified locks")
        first_bound=Float64(resumed.lower_bound)
        prior_diagnostic_seconds=Float64(resumed.cpu_time_seconds)+
            (hasproperty(resumed,:prior_diagnostic_seconds) ? Float64(resumed.prior_diagnostic_seconds) : 0.)
    end
    isempty(output_prefix) || mkpath(dirname(output_prefix))
    mlu_cutoff=completed>=1 ? max(maximum(validation.loads),locks[1])+1e-10 :
        maximum(validation.loads)+max(proof_tolerance,lock_tolerance)+1e-10
    master=if physical_certificate_supported(problem,mlu_cutoff)
        build_physical_certificate(problem,validation.paths;solver,time_limit=min(60.,time_limit),seed,threads,mlu_cutoff,max_variables,compact_lex,sr_refinement)
    else
        build_endpoint_certificate(problem;solver,time_limit=min(60.,time_limit),seed,threads,mlu_cutoff)
    end
    try
        if resumed!==nothing && hasproperty(resumed,:exact_sr_demand_indices)
            for d in Int.(resumed.exact_sr_demand_indices)
                1<=d<=problem.D || error("Invalid resumed demand index")
                refine_certificate_demand!(master,problem,d;max_variables,integer=true)
            end
        end
        for j in 1:completed
            if master.compact_lex
                order=sortperm(validation.loads;rev=true)
                add_compact_lex_upper!(master,j,order[1:j],locks[j])
            else
                old=add_lexicographic_stage!(master,j,problem.M);push!(master.stages,old)
                @constraint(master.model,old.expression<=locks[j])
            end
        end
        if master.compact_lex && resumed!==nothing && hasproperty(resumed,:lex_subset_keys) && resumed.lex_subset_keys!==nothing
            for (rank,sets) in pairs(resumed.lex_subset_keys)
                j=parse(Int,String(rank));1<=j<=completed || error("Invalid resumed lexicographic cut")
                for indices in sets;add_compact_lex_upper!(master,j,Int.(indices),locks[j]);end
            end
        end
        for k in completed+1:problem.M
            clear_compact_certificate_stage!(master)
            stage=add_certificate_lex_stage!(master,k,problem.M);push!(master.stages,stage);stage_bound=0.;round=0
            if resumed!==nothing && hasproperty(resumed,:active_stage) && resumed.active_stage==k && hasproperty(resumed,:stage_lower_bound)
                stage_bound=max(0.,Float64(resumed.stage_lower_bound))
            end
            cutoff_upper=sum(sort(validation.loads;rev=true)[1:k])
            cutoff=@constraint(master.model,stage.expression<=cutoff_upper+proof_tolerance)
            master.compact_lex && push!(master.transient_rows,cutoff)
            if stage_bound>proof_tolerance
                lower_cut=@constraint(master.model,stage.expression>=stage_bound-proof_tolerance)
                master.compact_lex && push!(master.transient_rows,lower_cut)
            end
            model_changed=true
            previous_native_nodes=0
            while elapsed<time_limit-.01
                round+=1;remaining=time_limit-elapsed
                continuing_tree=solver==:scip && round>1 && !model_changed
                slice=round>1 && !model_changed ? remaining : min(remaining,60.0 * 2.0^min(round-1,6))
                set_stage_time_limit!(master.model,solver,slice)
                if model_changed
                    warm_certificate!(master,problem,validation)
                    solver==:scip && install_complete_certificate_scip_start!(master.model)
                end
                solver==:highs && install_highs_deadline!(master.model,slice)
                native_log=isempty(output_prefix) ? "" : output_prefix*"_stage-"*lpad(k,3,'0')*"_round-"*lpad(round,2,'0')*"_"*String(solver)*".log"
                set_stage_log!(master.model,solver,native_log)
                write_solve_event(native_log,"start",slice,k)
                seconds=try
                    @elapsed optimize!(master.model)
                finally
                    close_stage_log!(master.model,solver)
                end
                write_solve_event(native_log,"end",max(0.,slice-seconds),k)
                elapsed+=seconds
                native_nodes=certificate_node_count(master.model,solver)
                nodes+=continuing_tree ? max(0,native_nodes-previous_native_nodes) : native_nodes
                previous_native_nodes=native_nodes
                model_changed=false
                solver_status=termination_status(master.model)
                solver==:scip && solver_status==ORANGE_MOI.INTERRUPTED && throw(InterruptException())
                native_feasible=primal_status(master.model)==ORANGE_MOI.FEASIBLE_POINT
                relaxed_incumbent=native_feasible ? objective_value(master.model) : Inf
                native_loads=native_feasible ? value.(master.loads) : Float64[]
                violated_prior=native_feasible ? compact_lex_violations(master,locks,native_loads) : Int[]
                solver_status==ORANGE_MOI.INFEASIBLE && error("Relaxation infeasible despite validated incumbent")
                bound=objective_bound(master.model)
                isfinite(bound) && (stage_bound=max(stage_bound,bound))
                offending=Int[]
                if primal_status(master.model)==ORANGE_MOI.FEASIBLE_POINT
                    extract_certificate_physical_routes!(route_pool,master,problem)
                    extract_certificate_flow_routes!(route_pool,master,problem)
                    candidate=certificate_candidate_paths(master,problem)
                    offending=prioritize_certificate_refinements(master,problem,candidate,k)
                    for d in 1:problem.D;add_certificate_route!(route_pool,problem,d,candidate.paths[d]);end
                    bridge_certificate_routes!(route_pool,problem,candidate,validation,k)
                    actual=validate_certificate_paths(problem,candidate.paths)
                    if actual!==nothing && certificate_candidate_improves(actual,validation,k,locks)
                        validation=actual
                    end
                end
                upper=sum(sort(validation.loads;rev=true)[1:k])
                route_seconds=0.
                if isempty(violated_prior) && upper-stage_bound>proof_tolerance && time_limit-elapsed>.01
                    for pricing_round in 1:30
                        time_limit-elapsed>.01 || break
                        priced=solve_certificate_route_pool(problem,route_pool,validation,k,locks;
                            time_limit=min(10.,time_limit-elapsed),seed,threads,integer=false)
                        route_seconds+=priced.seconds;elapsed+=priced.seconds
                        isnothing(priced.weights) && break
                        price_certificate_routes!(route_pool,problem,priced.weights)==0 && break
                    end
                end
                if isempty(violated_prior) && upper-stage_bound>proof_tolerance && time_limit-elapsed>.01
                    generated=solve_certificate_route_pool(problem,route_pool,validation,k,locks;
                        time_limit=min(20.,time_limit-elapsed),seed,threads)
                    route_seconds+=generated.seconds;elapsed+=generated.seconds;nodes+=generated.nodes
                    actual=generated.candidate
                    if actual!==nothing && certificate_candidate_improves(actual,validation,k,locks)
                        validation=actual;upper=sum(sort(validation.loads;rev=true)[1:k])
                    end
                end
                stage_bound<=upper+proof_tolerance || error("Integer relaxation bound exceeds incumbent")
                if upper<cutoff_upper-1e-12
                    set_normalized_rhs(cutoff,upper+proof_tolerance)
                    cutoff_upper=upper;model_changed=true
                end
                k==1 && (first_bound=max(first_bound,stage_bound))
                certified=upper-stage_bound<=proof_tolerance
                separated=!certified && native_feasible ? separate_compact_lex_locks!(master,locks,native_loads) : 0
                model_changed|=separated>0
                row=(;stage=k,round,upper,lower=stage_bound,gap=experiment_gap(upper,stage_bound),certified,
                    lex_cuts_added=separated,
                    certificate_reason=certified ? "global_bound_match" : "open_gap",
                    bound_formulation=String(master.kind),mlu_cutoff=master.mlu_cutoff,
                    native_total_nodes=native_nodes,
                    solver=String(solver),middle_flow_mode=master.middle_flow_mode,
                    relaxed_incumbent=native_feasible ? relaxed_incumbent : missing,
                    refined_demands=length(master.refined),variables=num_variables(master.model),
                    integer_refined_demands=count(v.integer for v in values(master.refined)),
                    optimize_seconds=seconds+route_seconds,route_optimize_seconds=route_seconds,route_columns=length(route_pool.columns),cumulative_optimize_seconds=elapsed,solver_status=string(solver_status))
                println("CERTIFICATE ",JSON3.write(row));flush(stdout)
                isempty(output_prefix) || append_result_csv(output_prefix*"_stages.csv",row)
                if certified
                    completed=k;push!(locks,upper+lock_tolerance)
                    if master.compact_lex
                        add_compact_lex_upper!(master,k,sortperm(validation.loads;rev=true)[1:k],locks[end])
                    else
                        @constraint(master.model,stage.expression<=locks[end])
                    end
                    vector=sort(validation.loads;rev=true)
                    if k<problem.M && all(iszero,vector[k+1:end])
                        # F_j >= F_k >= L_k and U_j == U_k prove every remaining rank.
                        for j in k+1:problem.M
                            push!(locks,upper+lock_tolerance)
                            inferred=merge(row,(;stage=j,round=0,certificate_reason="zero_suffix_monotonicity",
                                native_total_nodes=0,optimize_seconds=0.,route_optimize_seconds=0.,solver_status="INFERRED_ZERO_SUFFIX"))
                            isempty(output_prefix) || append_result_csv(output_prefix*"_stages.csv",inferred)
                        end
                        completed=problem.M
                    end
                end
                state=(;status=completed==problem.M ? "Optimal" : "Not Optimal",termination="RUNNING",
                    data_signature,prior_diagnostic_seconds,total_diagnostic_optimize_seconds=prior_diagnostic_seconds+elapsed,
                    certified_top_k_locks=copy(locks),
                    exact_sr_demand_indices=certificate_exact_demand_indices(master),
                    compact_lex=master.compact_lex,lex_subset_keys=compact_lex_snapshot(master),
                    proof_tolerance,lock_tolerance,temporal,budget_limit=temporal ? data.budget : nothing,
                    certificate_revision="adaptive_integer_endpoint_v1",
                    solver=String(solver),middle_flow_mode=master.middle_flow_mode,
                    validated=true,mlu=maximum(validation.loads),lower_bound=first_bound,gap=experiment_gap(maximum(validation.loads),first_bound),
                    active_stage=completed==problem.M ? problem.M : k,last_optimized_stage=k,
                    stage_objective=upper,stage_lower_bound=stage_bound,stage_gap=experiment_gap(upper,stage_bound),
                    lex_completed_stages=completed,lex_total_stages=problem.M,cpu_time_seconds=elapsed,wall_time_seconds=time()-started,
                    refined_demands=length(master.refined),srpaths=validation.srpaths,budget_used=validation.budget_used,
                    sorted_loads=sort(validation.loads;rev=true),
                    bound_scope=master.kind==:physical ? "full_domain_integer_physical_relaxation" : "full_domain_integer_endpoint_relaxation")
                if !isempty(output_prefix)
                    write(output_prefix*"_solution.json.tmp",JSON3.write(state));mv(output_prefix*"_solution.json.tmp",output_prefix*"_solution.json";force=true)
                end
                certified && break
                needs_refinement=separated==0 && native_feasible && relaxed_incumbent<upper-proof_tolerance
                if needs_refinement
                    for d in offending[1:min(refinement_batch,length(offending))]
                        restored=refine_certificate_demand!(master,problem,d;max_variables,integer=haskey(master.refined,d))
                        model_changed|=restored
                        restored && println("RESTORED_DEMAND ",JSON3.write((;demand_index=d,demand_id=problem.data.demand_ids[d],integer=master.refined[d].integer)))
                    end
                    state=merge(state,(;refined_demands=length(master.refined),
                        exact_sr_demand_indices=certificate_exact_demand_indices(master),variables=num_variables(master.model)))
                    if !isempty(output_prefix)
                        write(output_prefix*"_solution.json.tmp",JSON3.write(state));mv(output_prefix*"_solution.json.tmp",output_prefix*"_solution.json";force=true)
                    end
                end
            end
            completed==k || break
        end
        completed==problem.M && (termination="OPTIMAL")
        result=(;status=completed==problem.M ? "Optimal" : "Not Optimal",termination,validated=true,
            data_signature,prior_diagnostic_seconds,total_diagnostic_optimize_seconds=prior_diagnostic_seconds+elapsed,
            certified_top_k_locks=copy(locks),
            exact_sr_demand_indices=certificate_exact_demand_indices(master),
            compact_lex=master.compact_lex,lex_subset_keys=compact_lex_snapshot(master),
            proof_tolerance,lock_tolerance,temporal,budget_limit=temporal ? data.budget : nothing,
            certificate_revision="adaptive_integer_endpoint_v1",
            solver=String(solver),middle_flow_mode=master.middle_flow_mode,
            objective=maximum(validation.loads),lower_bound=first_bound,gap=experiment_gap(maximum(validation.loads),first_bound),
            lex_completed_stages=completed,lex_total_stages=problem.M,cpu_time_seconds=elapsed,wall_time_seconds=time()-started,
            refined_demands=length(master.refined),variables=num_variables(master.model),nodes,
            budget_used=validation.budget_used,srpaths=validation.srpaths,sorted_loads=sort(validation.loads;rev=true),
            bound_scope=master.kind==:physical ? "full_domain_integer_physical_relaxation" : "full_domain_integer_endpoint_relaxation")
        if !isempty(output_prefix)
            write(output_prefix*".json",JSON3.write(result))
            final_checkpoint=state===nothing ? result : merge(state,result)
            write(output_prefix*"_solution.json.tmp",JSON3.write(final_checkpoint))
            mv(output_prefix*"_solution.json.tmp",output_prefix*"_solution.json";force=true)
        end
        return result
    finally
        release_pair_model!(master.model)
    end
end

function extract_certificate_flow_routes!(pool,master,problem)
    master.kind==:physical && return 0
    added=0
    for (d,refinement) in master.refined
        flow=Dict(edge=>max(0.,value(v)) for (edge,v) in refinement.x if value(v)>1e-8)
        outgoing=[Int[] for v in 1:problem.n]
        for ((i,j),amount) in flow;push!(outgoing[i],j);end
        s,t=problem.sources[d],problem.targets[d]
        for component in 1:32
            parent=zeros(Int,problem.n);parent[s]=-1;queue=Int[s];head=1
            while head<=length(queue) && parent[t]==0
                i=queue[head];head+=1
                for j in outgoing[i]
                    parent[j]==0 && flow[i,j]>1e-8 || continue
                    parent[j]=i;push!(queue,j)
                end
            end
            parent[t]!=0 || break
            path=Int[t]
            while last(path)!=s;push!(path,parent[last(path)]);end
            reverse!(path);amount=minimum(flow[i,j] for (i,j) in zip(path,path[2:end]))
            for edge in zip(path,path[2:end]);flow[edge]-=amount;end
            added+=add_certificate_route!(pool,problem,d,path)>0
        end
    end
    return added
end

function certificate_weighted_path(costs,reachable,s,t,K;forbidden=Int[])
    n=size(costs,1);distance=fill(Inf,n,K+1);parent=zeros(Int,n,K+1);distance[s,1]=0.
    for h in 1:K,j in 1:n,i in 1:n
        reachable[i,j] && !(i in forbidden) && !(j in forbidden) || continue
        candidate=distance[i,h]+costs[i,j]
        if candidate<distance[j,h+1]-1e-12
            distance[j,h+1]=candidate;parent[j,h+1]=i
        end
    end
    h=argmin(distance[t,:]);isfinite(distance[t,h]) || return Int[]
    path=Int[t]
    while h>1;push!(path,parent[last(path),h]);h-=1;end
    reverse!(path);simple=Int[]
    for node in path
        at=findfirst(==(node),simple)
        isnothing(at) ? push!(simple,node) : resize!(simple,at)
    end
    return simple
end

function certificate_physical_path(problem,used,s,t)
    s==t && return Int[s]
    outgoing=[Int[] for v in 1:problem.n]
    for a in used;i,j=problem.data.arcs[a];push!(outgoing[i],j);end
    parent=zeros(Int,problem.n);parent[s]=-1;queue=Int[s];head=1
    while head<=length(queue) && parent[t]==0
        i=queue[head];head+=1
        for j in outgoing[i]
            parent[j]==0 || continue
            parent[j]=i;push!(queue,j)
        end
    end
    parent[t]!=0 || return Int[]
    path=Int[t]
    while last(path)!=s;push!(path,parent[last(path)]);end
    return reverse!(path)
end

function certificate_segment_physical_path(problem,t,i,j)
    i==j && return Int[i]
    matrix=problem.ratios[t];column=i+(j-1)*problem.n
    used=[rowvals(matrix)[h] for h in nzrange(matrix,column)]
    return certificate_physical_path(problem,used,i,j)
end

function compress_certificate_physical_path(problem,t,path)
    isempty(path) && return Int[]
    simple=Int[]
    for node in path
        at=findfirst(==(node),simple)
        isnothing(at) ? push!(simple,node) : resize!(simple,at)
    end
    arc_index=Dict(edge=>a for (a,edge) in enumerate(problem.data.arcs))
    edges=[arc_index[edge] for edge in zip(simple,simple[2:end])]
    result=Int[first(simple)];i=1;matrix=problem.ratios[t]
    while i<length(simple)
        next=0
        for j in length(simple):-1:i+1
            column=simple[i]+(simple[j]-1)*problem.n
            used=[rowvals(matrix)[h] for h in nzrange(matrix,column)]
            if length(used)==j-i && Set(used)==Set(edges[i:j-1]);next=j;break;end
        end
        next>0 || return Int[]
        push!(result,simple[next]);i=next
    end
    return result
end

function extract_certificate_physical_routes!(pool,master,problem)
    master.kind==:physical && return 0
    isempty(master.physical_middle) && return 0
    all(v==1. for matrix in problem.ratios for v in nonzeros(matrix)) || return 0
    added=0
    for ((d,t),variables) in master.physical_middle
        value(master.direct[d])>.5 && continue
        i=only([i for i in 1:problem.n if value(master.first_leg[d,i])>.5])
        j=only([j for j in 1:problem.n if value(master.last_leg[d,j])>.5])
        middle=certificate_physical_path(problem,findall(v->value(v)>.5,variables),i,j)
        isempty(middle) && continue
        initial=certificate_segment_physical_path(problem,t,problem.sources[d],i)
        final=certificate_segment_physical_path(problem,t,j,problem.targets[d])
        path=compress_certificate_physical_path(problem,t,vcat(initial,middle[2:end],final[2:end]))
        isempty(path) || (added+=add_certificate_route!(pool,problem,d,path)>0)
    end
    return added
end

function bridge_certificate_routes!(pool,problem,candidate,validation,k)
    problem.K>=3 || return 0
    loads=zeros(problem.M)
    for d in 1:problem.D,(i,j) in zip(candidate.paths[d],candidate.paths[d][2:end])
        loads+=certificate_segment_coefficients(problem,d,i,j)
    end
    weights=loads./max(maximum(loads),1e-10)
    for (rank,a) in enumerate(sortperm(validation.loads;rev=true)[1:k])
        weights[a]+=1000*(k-rank+1)
    end
    for a in sortperm(loads;rev=true)[1:k];weights[a]+=10.;end
    period_costs=[transpose(problem.ratios[t])*(weights[(t-1)*problem.m+1:t*problem.m]./problem.data.c) for t in eachindex(problem.ratios)]
    added=0
    for d in candidate.offending
        path=candidate.paths[d]
        costs=reshape(sum(problem.volumes[d,t].*period_costs[t] for t in eachindex(period_costs)),problem.n,problem.n)
        middle=certificate_weighted_path(costs,problem.reachable,path[2],path[end-1],problem.K-2;
            forbidden=Int[problem.sources[d],problem.targets[d]])
        isempty(middle) && continue
        added+=add_certificate_route!(pool,problem,d,vcat(problem.sources[d],middle,problem.targets[d]))>0
    end
    return added
end

function add_certificate_route!(pool,problem,d,path)
    length(path)-1<=problem.K && length(unique(path))==length(path) || return 0
    all(problem.reachable[i,j] for (i,j) in zip(path,path[2:end])) || return 0
    coefficients=spzeros(problem.M)
    for (i,j) in zip(path,path[2:end]);coefficients+=certificate_segment_coefficients(problem,d,i,j);end
    signature=coefficient_signature(coefficients)
    haskey(pool.signatures[d],signature) && return 0
    push!(pool.columns,(;d,path=copy(path),coefficients))
    p=length(pool.columns);push!(pool.groups[d],p);pool.signatures[d][signature]=p
    return p
end

function initial_certificate_route_pool(problem,validation)
    pool=(columns=NamedTuple[],groups=[Int[] for d in 1:problem.D],signatures=[Dict{Tuple,Int}() for d in 1:problem.D])
    for d in 1:problem.D
        s,t=problem.sources[d],problem.targets[d]
        add_certificate_route!(pool,problem,d,validation.paths[d])
        add_certificate_route!(pool,problem,d,Int[s,t])
        if problem.K>=2
            for i in 1:problem.n
                i in (s,t) || add_certificate_route!(pool,problem,d,Int[s,i,t])
            end
        end
    end
    return pool
end

function solve_certificate_route_pool(problem,pool,validation,k,locks;time_limit=10.,seed=1,threads=1,integer=true)
    model=create_time0_optimizer(:highs;time_limit,seed,threads)
    set_string_names_on_creation(model,false)
    for name in ("primal_feasibility_tolerance","dual_feasibility_tolerance","mip_feasibility_tolerance")
        set_optimizer_attribute(model,name,1e-9)
    end
    y=@variable(model,[1:length(pool.columns)],lower_bound=0.,upper_bound=1.,binary=integer)
    loads=@variable(model,[1:problem.M],lower_bound=0.);z=@variable(model,lower_bound=0.)
    expressions=[AffExpr(0.) for a in 1:problem.M]
    for (p,c) in enumerate(pool.columns);certificate_add_coefficients!(expressions,y[p],c.coefficients);end
    convexity=@constraint(model,[d in 1:problem.D],sum(y[p] for p in pool.groups[d])==1)
    load_rows=@constraint(model,[a in 1:problem.M],expressions[a]<=loads[a])
    @constraint(model,[a in 1:problem.M],loads[a]<=z)
    stages=NamedTuple[]
    for j in eachindex(locks)
        old=add_lexicographic_stage!((;model,loads,z),j,problem.M)
        @constraint(model,old.expression<=locks[j]);push!(stages,old)
    end
    current=add_lexicographic_stage!((;model,loads,z),k,problem.M);push!(stages,current)
    for variable in y;set_start_value(variable,0.);end
    for d in 1:problem.D
        coefficients=spzeros(problem.M)
        for (i,j) in zip(validation.paths[d],validation.paths[d][2:end]);coefficients+=certificate_segment_coefficients(problem,d,i,j);end
        p=pool.signatures[d][coefficient_signature(coefficients)];set_start_value(y[p],1.)
    end
    sorted=sort(validation.loads;rev=true)
    for a in 1:problem.M;set_start_value(loads[a],validation.loads[a]);end
    set_start_value(z,maximum(validation.loads))
    for stage in stages
        isnothing(stage.threshold) && continue
        set_start_value(stage.threshold,sorted[stage.k])
        for a in 1:problem.M;set_start_value(stage.excess[a],max(0.,validation.loads[a]-sorted[stage.k]));end
    end
    try
        install_highs_deadline!(model,time_limit)
        seconds=@elapsed optimize!(model)
        candidate=nothing
        if integer && primal_status(model)==ORANGE_MOI.FEASIBLE_POINT
            paths=[pool.columns[only([p for p in pool.groups[d] if value(y[p])>.5])].path for d in 1:problem.D]
            candidate=validate_certificate_paths(problem,paths)
        end
        # Restricted-master bounds never enter the full-domain certificate.
        weights=!integer && dual_status(model)==ORANGE_MOI.FEASIBLE_POINT ? max.(0.,-dual.(load_rows)) : nothing
        return (;seconds,candidate,nodes=integer ? node_count(model) : 0,weights)
    finally
        release_pair_model!(model)
    end
end

function price_certificate_routes!(pool,problem,weights)
    period_costs=[transpose(problem.ratios[t])*(weights[(t-1)*problem.m+1:t*problem.m]./problem.data.c) for t in eachindex(problem.ratios)]
    added=0;n=problem.n
    for d in 1:problem.D
        costs=reshape(sum(problem.volumes[d,t].*period_costs[t] for t in eachindex(period_costs)),n,n)
        distance=fill(Inf,n,problem.K+1);parent=zeros(Int,n,problem.K+1)
        s,t=problem.sources[d],problem.targets[d];distance[s,1]=0.
        for h in 1:problem.K,j in 1:n,i in 1:n
            problem.reachable[i,j] || continue
            candidate=distance[i,h]+costs[i,j]
            if candidate<distance[j,h+1]-1e-12
                distance[j,h+1]=candidate;parent[j,h+1]=i
            end
        end
        h=argmin(distance[t,:]);isfinite(distance[t,h]) || continue
        path=Int[t]
        while h>1;push!(path,parent[last(path),h]);h-=1;end
        reverse!(path)
        # Nonnegative costs allow deleting cycles before storing a real SR route.
        simple=Int[]
        for node in path
            at=findfirst(==(node),simple)
            isnothing(at) ? push!(simple,node) : resize!(simple,at)
        end
        added+=add_certificate_route!(pool,problem,d,simple)>0
    end
    return added
end
