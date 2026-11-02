using Test

@testset "Optimize-call budget does not impose an implicit wall cutoff" begin
    @test experiment_wall_deadline(10.) == Inf
    @test experiment_wall_deadline(10.,2.) == 12.
    @test_throws ErrorException experiment_wall_deadline(10.,0.)
    @test_throws ErrorException experiment_wall_deadline(10.,Inf)
    data=time0_demo_data()
    mktempdir() do directory
        result=solve_time0(data;formulation=:routes,time_limit=5.,warm_start_seconds=0.,
            max_routes_per_demand=1,pricing_rounds=1,log_file=joinpath(directory,"budget.log"))
        @test result.validated
        @test result.gap <= 1e-7
        @test result.status == "Optimal"
        @test result.lex_completed_stages == result.lex_total_stages == 4
        @test Float64.(JSON3.read(result.sorted_loads_json)) ≈ [1.,.5,.5,0.] atol=1e-6
        rows=readlines(joinpath(directory,"budget_stages.csv"))
        header=split(first(rows),',')
        stage=findfirst(==("stage"),header)
        proof=findfirst(==("globally_certified"),header)
        @test any(row -> begin
            fields=split(row,',');strip(fields[stage],'"')=="1" && strip(fields[proof],'"')=="true"
        end,rows[2:end])
        @test length(rows)>4
        println("TIME0_BUDGET_PROOF status=",result.status," gap=",result.gap,
            " stages=",result.lex_completed_stages,"/",result.lex_total_stages,
            " vector=",result.sorted_loads_json," optimize_seconds=",result.cpu_time_seconds)
    end
    limited=solve_time0(data;formulation=:routes,time_limit=5.,wall_time_limit=1e-9,warm_start_seconds=0.)
    @test limited.termination == "SEARCH_WALL_LIMIT"
    @test limited.status == "Not Optimal"

    temporal=load_time01_data(joinpath(@__DIR__,"fixtures/orange_subject_toy/toy"))
    singleton=merge(temporal,(MaxSeg=1,budget=0))
    result=solve_time01(singleton;time_limit=10.)
    @test result.validated && result.budget_used==0
    @test result.status=="Optimal"
    @test result.lex_completed_stages==result.lex_total_stages==44
    @test result.gap<=1e-6
    println("TIME01_BUDGET_PROOF status=",result.status," gap=",result.gap,
        " stages=",result.lex_completed_stages,"/",result.lex_total_stages,
        " optimize_seconds=",result.cpu_time_seconds)
end
