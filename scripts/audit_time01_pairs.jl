# Small fixtures only. No original SetA batch and no cloud operations.
include(joinpath(@__DIR__,"..","Project_Orange.jl"))
using Test
include(joinpath(@__DIR__,"..","test","paired_pricing.jl"))

function audit_time01_pairs(;output_dir=joinpath(@__DIR__,"..","results","time01_paired_validation"))
    mkpath(output_dir)
    fixture=joinpath(@__DIR__,"..","test","fixtures","orange_subject_toy")
    data=load_time01_data(joinpath(fixture,"toy"))
    observations=NamedTuple[]
    for budget in (20,0)
        stem=joinpath(output_dir,"budget$(budget)")
        result=solve_time01(merge(data,(;budget));time_limit=2.,log_file=stem*"_cycles.csv",solution_file=stem*"_solution.json")
        paths=stem*"_srpaths.json";write(paths,JSON3.write((srpaths=result.srpaths,)))
        if haskey(ENV,"ORANGE_CHECKER")
            scenario=JSON3.read(read(joinpath(fixture,"toy-scenario.json"),String),Dict{String,Any})
            for entry in scenario["budget"]
                entry["t"]==1 && (entry["value"]=budget)
            end
            scenario_file=stem*"_scenario.json";write(scenario_file,JSON3.write(scenario))
            command=Cmd([ENV["ORANGE_CHECKER"],"--net",joinpath(fixture,"toy-net.json"),
                "--tm",joinpath(fixture,"toy-tm.json"),"--scenario",scenario_file,"--srpaths",paths])
            checked=read(command,String);write(stem*"_checker.json",checked)
            report=JSON3.read(checked)
            @test report.valid
            @test report.total_cost==result.budget_used
            vector=sort(Float64[x.sat for x in report.saturations];rev=true)
            append!(vector,zeros(length(result.sorted_loads)-length(vector)))
            @test vector≈result.sorted_loads atol=1e-9
        end
        push!(observations,(;budget,status=result.status,termination=result.termination,mlu=result.objective,
            global_bound=result.lower_bound,gap=result.gap,budget_used=result.budget_used,
            certified=result.lex_completed_stages,total=result.lex_total_stages,pair_columns=result.columns,
            pricing_calls=result.pricing_calls,optimize_seconds=result.cpu_time_seconds,
            pricing_seconds=result.pricing_optimize_seconds,wall_seconds=result.wall_time_seconds))
    end
    write(joinpath(output_dir,"summary.json"),JSON3.write(observations))
    println("PAIRED_AUDIT ",JSON3.write(observations))
    return observations
end

if abspath(PROGRAM_FILE)==@__FILE__
    audit_time01_pairs()
end
