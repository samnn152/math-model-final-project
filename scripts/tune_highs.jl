using JSON3, Dates
include(joinpath(@__DIR__,"..","Project_Orange.jl"))

function tune_highs(directory; instances=[1,4],seconds=30.0)
    isdir(directory) && error("Choose a new output directory")
    mkpath(directory)
    warm_up_solver(:highs;threads=1)
    rows=NamedTuple[]
    for id in instances
        data=load_data(joinpath(@__DIR__,"..","setA","setA-"*lpad(id,2,'0')))
        for profile in (:default,:devex,:incumbent,:lean)
            GC.gc()
            name="setA-"*lpad(id,2,'0')*"_"*String(profile)
            println("START ",name);flush(stdout)
            measured=@timed solve_time0(data;solver=:highs,highs_profile=profile,
                instance="setA-"*lpad(id,2,'0'),time_limit=seconds,seed=1001,threads=1,
                log_file=joinpath(directory,name*".log"),solution_file=joinpath(directory,name*"_solution.json"))
            row=merge(measured.value,(wall_seconds=measured.time,))
            push!(rows,row)
            write(joinpath(directory,name*".json"),JSON3.write(row))
            append_result_csv(joinpath(directory,"runs.csv"),row)
            println("DONE ",name," time=",row.cpu_time_seconds," mlu=",row.objective,
                " gap=",row.gap," stages=",row.lex_completed_stages," quality=",row.quality_status);flush(stdout)
        end
    end
    return rows
end

if abspath(PROGRAM_FILE)==@__FILE__
    tune_highs(abspath(isempty(ARGS) ? "results/highs_tuning" : ARGS[1]))
end
