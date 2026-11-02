using Test

@testset "Exact integer endpoint certificate and safe refinement" begin
    demo=time0_demo_data()
    result=solve_adaptive_integer_certificate(demo;time_limit=15.)
    @test result.validated && result.status=="Optimal"
    @test result.lex_completed_stages==result.lex_total_stages==4
    @test result.sorted_loads≈[1.,.5,.5,0.] atol=1e-5
    scip=solve_adaptive_integer_certificate(demo;solver=:scip,time_limit=15.)
    @test scip.status=="Optimal"
    @test scip.lex_completed_stages==4
    @test scip.sorted_loads≈result.sorted_loads atol=1e-7
    fixture=joinpath(@__DIR__,"fixtures/orange_subject_toy")
    data=load_time01_data(joinpath(fixture,"toy"))
    oracle=JSON3.read(read(joinpath(fixture,"expected_time01.json"),String))
    for budget in (0,1)
        result=solve_adaptive_integer_certificate(merge(data,(;budget));temporal=true,time_limit=30.)
        @test result.validated && result.status=="Optimal"
        @test result.lex_completed_stages==result.lex_total_stages==44
        @test result.budget_used==0
        @test result.sorted_loads≈Float64.(oracle.budget0.sorted_loads) atol=1e-5
        @test result.bound_scope=="full_domain_integer_endpoint_relaxation"
    end
    temporal_scip=solve_adaptive_integer_certificate(merge(data,(budget=0,));temporal=true,solver=:scip,time_limit=30.)
    @test temporal_scip.status=="Optimal"
    @test temporal_scip.lex_completed_stages==44
    @test temporal_scip.sorted_loads≈Float64.(oracle.budget0.sorted_loads) atol=1e-5
    @test_throws ErrorException certificate_problem(merge(data,(budget=2,));temporal=true)
    @test_throws ErrorException certificate_problem(merge(data,(budget=-1,));temporal=true)
    @test_throws ErrorException build_endpoint_certificate(certificate_problem(data;temporal=true);middle_flow=:integer)
    problem=certificate_problem(demo)
    master=build_endpoint_certificate(problem)
    try
        @test master.middle_flow_mode=="binary_deterministic"
        @test_throws ErrorException refine_certificate_demand!(master,problem,1;max_variables=1)
        @test isempty(master.refined)
        @test refine_certificate_demand!(master,problem,1)
        @test !refine_certificate_demand!(master,problem,1)
    finally
        release_pair_model!(master.model)
    end
end

@testset "Screened paths and exact coefficient aliases" begin
    costs=[Inf 1. 4.; Inf Inf 1.; Inf Inf Inf]
    result=screen_route_paths(costs,1,3,2,2.1)
    @test result.complete && result.paths==[[1,2,3]]
    limited=screen_route_paths(costs,1,3,2,10.;max_visits=1)
    @test !limited.complete
    data=time0_demo_data();pool=initial_route_pool(data)
    @test length(pool.coefficient_keys)==length(data.v)
end

@testset "Certificate resume preserves ranks and rejects changed data" begin
    directory=mktempdir()
    try
        data=time0_demo_data();prefix=joinpath(directory,"complete")
        full=solve_adaptive_integer_certificate(data;time_limit=15.,output_prefix=prefix)
        saved=JSON3.read(read(prefix*"_solution.json",String),Dict{String,Any})
        saved["lex_completed_stages"]=2
        saved["certified_top_k_locks"]=saved["certified_top_k_locks"][1:2]
        saved["status"]="Not Optimal";saved["active_stage"]=3;saved["stage_lower_bound"]=0.
        checkpoint=joinpath(directory,"prefix.json");write(checkpoint,JSON3.write(saved))
        next_prefix=joinpath(directory,"resumed")
        result=solve_adaptive_integer_certificate(data;time_limit=15.,resume_checkpoint=checkpoint,output_prefix=next_prefix)
        @test result.status=="Optimal"
        @test result.lex_completed_stages==4
        @test result.sorted_loads≈full.sorted_loads atol=1e-7
        @test result.prior_diagnostic_seconds≈full.cpu_time_seconds
        rows=readlines(next_prefix*"_stages.csv")[2:end]
        @test [parse(Int,replace(first(split(row,',')),"\""=>"")) for row in rows]==[3,4]
        @test occursin("zero_suffix_monotonicity",last(rows))
        @test_throws ErrorException solve_adaptive_integer_certificate(merge(data,(c=data.c.*2,));resume_checkpoint=checkpoint)
    finally
        rm(directory;recursive=true)
    end
end

@testset "SCIP continues a limited solve without resubmitting partial starts" begin
    model=create_time0_optimizer(:scip;time_limit=10.,seed=1,threads=1)
    try
        set_optimizer_attribute(model,"presolving/maxrounds",0)
        set_optimizer_attribute(model,"limits/nodes",0)
        x=@variable(model,[1:3],binary=true)
        @constraint(model,6x[1]+4x[2]+3x[3]<=8)
        @objective(model,Max,10x[1]+7x[2]+5x[3])
        for i in 1:3;set_start_value(x[i],i==1 ? 1. : 0.);end
        install_complete_certificate_scip_start!(model)
        optimize!(model)
        @test termination_status(model)==ORANGE_MOI.NODE_LIMIT
        @test objective_value(model)≈10.
        set_optimizer_attribute(model,"limits/nodes",-1)
        set_stage_time_limit!(model,:scip,10.)
        optimize!(model)
        @test termination_status(model)==ORANGE_MOI.OPTIMAL
        @test objective_value(model)≈12.
    finally
        release_pair_model!(model)
    end
end

@testset "Temporal physical coupling preserves original route mappings" begin
    directory=mktempdir()
    try
        fixture=joinpath(@__DIR__,"fixtures/orange_subject_toy")
        prefix=joinpath(directory,"unique")
        for suffix in ("net","tm","scenario")
            cp(joinpath(fixture,"toy-$(suffix).json"),prefix*"-$(suffix).json")
        end
        net=JSON3.read(read(prefix*"-net.json",String),Dict{String,Any})
        for (i,arc) in enumerate(net["links"]);arc["metric"]=1_000_000_000+2^(i-1);end
        write(prefix*"-net.json",JSON3.write(net))
        data=merge(load_time01_data(prefix),(budget=1,))
        problem=certificate_problem(data;temporal=true)
        @test all(v==1. for matrix in problem.ratios for v in nonzeros(matrix))
        failure=certificate_failure_coupling(problem)
        @test failure.valid && !isempty(failure.affected)
        master=build_endpoint_certificate(problem)
        try
            @test master.middle_flow_mode=="coupled_integer_deterministic"
        finally
            release_pair_model!(master.model)
        end
        mappings_valid=true;checked=0
        for d in 1:problem.D,i in 1:problem.n,j in 1:problem.n,h in 1:problem.n
            path=Int[problem.sources[d],i,j,h,problem.targets[d]]
            length(unique(path))==length(path) || continue
            all(problem.reachable[u,v] for (u,v) in zip(path,path[2:end])) || continue
            flows=[[sum(period.r.values[u+(v-1)*problem.n,a]
                for (u,v) in zip(path[2:end-1],path[3:end-1]);init=0.)
                for a in 1:problem.m] for period in data.periods]
            checked+=1
            mappings_valid&=all(isinteger(x) && 0<=x<=problem.K-2 for f in flows for x in f)
            if sum(flows[1][failure.affected])==0
                mappings_valid&=flows[1]==flows[2]
            end
        end
        @test checked>0 && mappings_valid
        allowed=copy(problem.reachable)
        for j in 1:problem.n,i in 1:problem.n
            any(data.periods[1].r.values[i+(j-1)*problem.n,a]>0 for a in failure.affected) && (allowed[i,j]=false)
        end
        paths=[certificate_weighted_path(ones(problem.n,problem.n),allowed,problem.sources[d],problem.targets[d],problem.K) for d in 1:problem.D]
        @test all(!isempty(path) for path in paths)
        failed_ids=Set(data.arc_ids[failure.affected])
        for arc in net["links"];arc["id"] in failed_ids && (arc["capacity"]=1e-6);end
        write(prefix*"-net.json",JSON3.write(net))
        data=merge(load_time01_data(prefix),(budget=1,))
        problem=certificate_problem(data;temporal=true)
        validation=validate_certificate_paths(problem,paths)
        @test validation!==nothing && validation.budget_used==0
        upper=maximum(validation.loads)+1e-7
        master=build_endpoint_certificate(problem;mlu_cutoff=upper,time_limit=5.)
        try
            @test master.middle_flow_mode=="shared_binary_deterministic_cutoff"
            @test isempty(master.physical_change_flags)
            @test all(master.physical_middle[d,1]===master.physical_middle[d,2] for d in 1:problem.D)
            stage=add_lexicographic_stage!(master,1,problem.M);push!(master.stages,stage)
            warm_certificate!(master,problem,validation)
            optimize!(master.model)
            @test primal_status(master.model)==ORANGE_MOI.FEASIBLE_POINT
            @test objective_bound(master.model)<=upper+1e-7
        finally
            release_pair_model!(master.model)
        end
    finally
        rm(directory;recursive=true)
    end
end

@testset "Physical certificate must restore the original MaxSeg restriction" begin
    directory=mktempdir()
    try
        prefix=joinpath(directory,"maxseg")
        arcs=[(0,1,10.,1.),(1,2,10.,1.),(2,3,10.,1.),(0,2,1.,.1),(1,3,1.,.2)]
        net=(directed=true,multigraph=false,
            nodes=[(id=i,name=string(i)) for i in 0:3],
            links=[(from=i,to=j,capacity=c,metric=w,id=a-1) for (a,(i,j,c,w)) in enumerate(arcs)])
        tm=(num_time_slots=2,demands=[(s=0,t=3,v=[1.,2.])])
        scenario=(max_segments=2,budget=[(t=1,value=1)],interventions=[(t=1,links=Int[])])
        write(prefix*"-net.json",JSON3.write(net))
        write(prefix*"-tm.json",JSON3.write(tm))
        write(prefix*"-scenario.json",JSON3.write(scenario))
        for (temporal,compact_lex,sr_refinement) in
                ((false,false,:segment),(true,false,:segment),(false,true,:segment),(true,true,:segment),
                 (false,false,:layered),(true,false,:layered),(false,true,:layered),(true,true,:layered))
            data=temporal ? load_time01_data(prefix) : load_data(prefix)
            result=solve_adaptive_integer_certificate(data;temporal,compact_lex,sr_refinement,time_limit=30.)
            @test result.status=="Optimal"
            @test result.refined_demands==1
            @test result.lex_completed_stages==result.lex_total_stages==(temporal ? 10 : 5)
            expected=temporal ? vcat([2.,1.,.2,.1],zeros(6)) : [1.,.1,0.,0.,0.]
            @test result.sorted_loads≈expected atol=1e-7
            @test result.bound_scope=="full_domain_integer_physical_relaxation"
        end
        scip_result=solve_adaptive_integer_certificate(load_time01_data(prefix);
            temporal=true,compact_lex=true,sr_refinement=:layered,solver=:scip,time_limit=30.)
        @test scip_result.status=="Optimal"
        @test scip_result.refined_demands==1
        @test scip_result.sorted_loads≈vcat([2.,1.,.2,.1],zeros(6)) atol=1e-7
    finally
        rm(directory;recursive=true)
    end
end

@testset "Compact lexicographic locks separate the missing top-k subset" begin
    directory=mktempdir()
    try
        for solver in (:highs,:scip)
            prefix=joinpath(directory,String(solver))
            result=solve_adaptive_integer_certificate(time0_demo_data();solver,compact_lex=true,
                time_limit=15.,output_prefix=prefix)
            @test result.status=="Optimal" && result.lex_completed_stages==4
            @test result.sorted_loads≈[1.,.5,.5,0.] atol=1e-7
            @test result.variables<=18
            lines=readlines(prefix*"_stages.csv")
            column=findfirst(==("lex_cuts_added"),split(first(lines),','))
            added=sum(parse(Int,replace(split(line,',')[column],"\""=>"")) for line in lines[2:end])
            @test added>=1
        end
    finally
        rm(directory;recursive=true)
    end
end
