using Test
root=get(ENV,"ORANGE_CERTIFICATE_OUTPUT",joinpath(@__DIR__,"..","results","local_setA05_integer_certificate_20261024_attempt02"))
mkpath(root)
ENV["ORANGE_DEMO_OUTPUT_ROOT"]=joinpath(root,"notebook_demos",string(getpid()))
include(joinpath(@__DIR__,"..","Project_Orange.jl"))
include(joinpath(@__DIR__,"..","test","adaptive_integer_certificate.jl"))
for stage_number in parse.(Int,split(get(ENV,"ORANGE_CERTIFICATE_STAGES","6,9"),','))
    stage_number in (6,9) || error("Only stages 6 and 9 are supported")
    temporal=stage_number==9
    stage=temporal ? 9 : 6
    prefix=joinpath(root,"step$(stage)")
    data=temporal ? load_time01_data(joinpath(@__DIR__,"..","setA","setA-05")) : load_data(joinpath(@__DIR__,"..","setA","setA-05"))
    old=get(ENV,"ORANGE_CERTIFICATE_INCUMBENT",joinpath(@__DIR__,"..","results","local_setA05_real_budget_20261024","step$(stage)","experiment","setA-05_run-01_solution.json"))
    println("START_SET05_CERTIFICATE step=",stage," original_budget=",temporal ? data.budget : "not applicable");flush(stdout)
    limit=parse(Float64,get(ENV,"ORANGE_CERTIFICATE_TIME_LIMIT",temporal ? "3600" : "1800"))
    result=solve_adaptive_integer_certificate(data;temporal,time_limit=limit,
        incumbent_file=old,output_prefix=prefix,refinement_batch=4,solver=Symbol(get(ENV,"ORANGE_CERTIFICATE_SOLVER","highs")),
        resume_checkpoint=get(ENV,"ORANGE_CERTIFICATE_RESUME",""),
        compact_lex=get(ENV,"ORANGE_CERTIFICATE_COMPACT_LEX","0")=="1",
        sr_refinement=Symbol(get(ENV,"ORANGE_CERTIFICATE_SR_REFINEMENT","segment")))
    result_summary=(;result.status,result.termination,result.objective,result.lower_bound,result.gap,
        result.lex_completed_stages,result.lex_total_stages,result.cpu_time_seconds,
        result.prior_diagnostic_seconds,result.total_diagnostic_optimize_seconds,
        result.wall_time_seconds,result.budget_used,result.bound_scope)
    println("FINAL_SET05_CERTIFICATE step=",stage," ",JSON3.write(result_summary));flush(stdout)
    @test result.validated
    @test result.gap<=1e-6
    @test result.status=="Optimal"
    @test result.lex_completed_stages==result.lex_total_stages
end
