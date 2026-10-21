using Test, JSON3
# The main test file includes Project_Orange.jl before this file.
@testset "Full lexicographic objective, not MLU alone" begin
    data = time0_demo_data()
    output = mktempdir()
    result = solve_time0(data; solver=:scip, time_limit=5.0,
        log_file=joinpath(output,"trial.log"),solution_file=joinpath(output,"solution.json"))
    @test result.status == "Optimal"
    @test result.solver == "scip"
    @test result.solver_version == orange_solver_version(:scip)
    @test result.lex_completed_stages == result.lex_total_stages == 4
    @test result.validated
    threaded = solve_time0(data; solver=:scip,time_limit=3.0, threads=2)
    @test threaded.status == "Optimal"
    @test threaded.lex_completed_stages == 4
    @test result.objective ≈ 1.0 atol=1e-5
    @test collect(JSON3.read(result.sorted_loads_json)) ≈ [1.,.5,.5,0.] atol=1e-5
    @test result.gap ≈ 0.0 atol=1e-5
    stages = readlines(result.log_file)
    @test length(stages) == 5
    @test isfile(joinpath(output,"trial_stage-001.log"))
    solution = JSON3.read(read(result.solution_file,String))
    @test solution.srpaths[2].w == [3]
    highs = solve_time0(data; solver=:highs,time_limit=5.0,
        log_file=joinpath(output,"highs.log"),solution_file=joinpath(output,"highs_solution.json"))
    @test highs.status == "Optimal"
    @test highs.solver == "highs"
    @test highs.lex_completed_stages == 4
    @test collect(JSON3.read(highs.sorted_loads_json)) ≈ collect(JSON3.read(result.sorted_loads_json)) atol=1e-5
    @test occursin("SCIP Status",read(joinpath(output,"trial_stage-004.log"),String))
    @test occursin("HiGHS",read(joinpath(output,"highs_stage-001.log"),String))
    @test JSON3.read(read(highs.solution_file,String)).solver == "highs"
    scip_stages = readlines(result.log_file)
    @test occursin("solver_time_limit",first(scip_stages))
    mixed_summary = summarize_experiments([result,highs],joinpath(output,"both_summary.csv"))
    @test length(mixed_summary) == 2
    @test Set(row.solver for row in mixed_summary) == Set(["scip","highs"])
    @test_throws ErrorException solve_time0(data;solver=:unknown)
    # Exhaust both possible simple segment routes of the second demand.
    direct = sort([1.0,.8,0.0,0.0]; rev=true)
    via_waypoint = sort([1.0,0.0,.5,.5]; rev=true)
    @test direct[1] == via_waypoint[1]
    @test via_waypoint[2] < direct[2]
    @test collect(JSON3.read(result.sorted_loads_json)) ≈ via_waypoint atol=1e-5
    @test experiment_gap(missing,0.0) === missing
    @test experiment_gap(0.0,0.0) == 0.0
    @test experiment_gap(2.0,1.0) == 0.5
    @test_throws ErrorException build_time0_model(data; max_binary_variables=1)
    limited = solve_time0(data; time_limit=1e-6)
    @test limited.status == "Not Optimal"
    @test limited.lex_completed_stages < limited.lex_total_stages
    @test limited.status != "Infeasible"
    @test ismissing(limited.lower_bound) || abs(limited.lower_bound) < 1e20
    @test ismissing(limited.stage_lower_bound) || abs(limited.stage_lower_bound) < 1e20
    if !limited.feasible
        @test ismissing(limited.objective)
        @test ismissing(limited.gap)
    end
end

@testset "CSV, missing values, summary and resume" begin
    output = mktempdir()
    rows = [(instance="test",value=missing,note="a,b\"c"),
            (instance="test",value=1.0,note="second")]
    csv = joinpath(output,"escape.csv")
    for row in rows
        append_result_csv(csv,row)
    end
    @test length(readlines(csv)) == 3
    @test occursin("\"a,b\"\"c\"",read(csv,String))
    @test result_mean(rows,:value) == 1.0
    batchdir = joinpath(output,"batch")
    batch = run_seta_experiments(; instances=[1],runs=2,time_limit=.01,
        max_binary_variables=1,output_dir=batchdir)
    @test length(batch.rows) == 2
    @test all(row.termination == "MODEL_SIZE_LIMIT" for row in batch.rows)
    @test all(ismissing(row.objective) for row in batch.rows)
    @test only(batch.summary).executed_runs == 0
    @test only(batch.summary).error_runs == 2
    @test ismissing(only(batch.summary).objective_mean)
    resumed = run_seta_experiments(; instances=[1],runs=2,time_limit=.01,
        max_binary_variables=1,output_dir=batchdir)
    @test length(resumed.rows) == 2
    @test experiment_summary_table(resumed.summary) isa Markdown.MD
    @test length(readlines(joinpath(batchdir,"runs.csv"))) == 3
    @test_throws ErrorException run_seta_experiments(; solver=:scip, instances=[1],runs=2,
        time_limit=.01,max_binary_variables=1,output_dir=batchdir)
    @test_throws ErrorException run_seta_experiments(; instances=[1],runs=3,
        time_limit=.01,max_binary_variables=1,output_dir=batchdir)
end

@testset "HiGHS profiles and honest approximation labels" begin
    data = time0_demo_data()
    @test solve_time0(data;time_limit=5.0).solver == "highs"
    for profile in (:default,:devex,:incumbent,:lean)
        result = solve_time0(data;solver=:highs,highs_profile=profile,time_limit=5.0)
        @test result.status == "Optimal"
        @test result.quality_status == "LEX_OPTIMAL"
        @test result.mlu_target_met
        @test collect(JSON3.read(result.sorted_loads_json)) ≈ [1.,.5,.5,0.] atol=1e-5
    end
    @test approximation_quality(true,.04,.20,1,4,.05).quality_status == "MLU_TARGET_MET_LEX_INCOMPLETE"
    @test !approximation_quality(true,.04,.20,1,4,.05).active_stage_target_met
    @test approximation_quality(true,.06,.20,0,4,.05).quality_status == "TARGET_NOT_MET"
    @test !approximation_quality(true,missing,missing,0,4,.05).mlu_target_met
    @test approximation_quality(false,missing,missing,0,4,.05).quality_status == "NO_FEASIBLE_SOLUTION"
    @test_throws ErrorException highs_search_options(:unknown)
    @test_throws ErrorException solve_time0(data;solver=:scip,highs_profile=:lean)
    @test_throws ErrorException solve_time0(data;target_gap=-.1)
end
