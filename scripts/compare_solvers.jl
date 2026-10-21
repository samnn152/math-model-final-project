using JSON3, Dates, SHA
include(joinpath(@__DIR__, "..", "Project_Orange.jl"))

function observe_comparison_stage(model, solver, stage, log_path)
    isempty(log_path) && return nothing
    backend = unsafe_backend(model)
    stats_path = replace(log_path, r"\.log$" => "_statistics.json")
    if solver == :scip
        stream = ccall(:fopen, Ptr{Base.Libc.FILE}, (Cstring, Cstring), stats_path, "w")
        stream == C_NULL && error("Cannot open SCIP statistics file")
        try
            status = SCIP.SCIPprintStatisticsJson(backend, stream)
            status == SCIP.SCIP_OKAY || error("Cannot export SCIP statistics: $status")
        finally
            ccall(:fclose, Cint, (Ptr{Base.Libc.FILE},), stream)
        end
    else
        statistics = (stage=stage, nodes=node_count(model),
            simplex_iterations=MOI.get(model, MOI.SimplexIterations()),
            root_first_lp_seconds=nothing,
            root_timing_note="Native HiGHS info does not expose an equivalent first-root-LP timer here; use timestamped progress log with stated precision.")
        write(stats_path, JSON3.write(statistics))
    end
    return nothing
end

function compare_solvers(; output_dir, time_limit=30.0)
    isdir(output_dir) && error("Use a new output directory to preserve previous trials")
    mkpath(output_dir)
    notebook = joinpath(@__DIR__, "..", "Project_Orange.jl")
    config = (created_utc=string(Dates.now(Dates.UTC)),instances=[1,2,4],runs=1,
        time_limit=time_limit,seed=1001,threads=1,splitting="uniform_paths",formulation="compact",highs_profile="default",
        objective="lexicographic_sorted_loads",lock_tolerance=1e-7,
        relative_gap_tolerance=0.0,absolute_gap_tolerance=1e-8,
        feasibility_tolerance=1e-7,notebook_sha256=bytes2hex(sha256(read(notebook))),
        julia=string(VERSION),scip=orange_solver_version(:scip),highs=orange_solver_version(:highs),
        cpu=Sys.CPU_NAME,kernel=string(Sys.KERNEL),
        notes="Sequential exploratory trial; initialization, construction and statistics export excluded from optimize! timings. No custom cuts, pricing or branching. Data convention unchanged.")
    write(joinpath(output_dir,"config.json"),JSON3.write(config))
    cp(notebook,joinpath(output_dir,"notebook_snapshot.jl"))
    for solver in (:scip,:highs)
        warm_up_solver(solver;threads=1)
    end
    rows = NamedTuple[]
    for id in (1,2,4)
        instance = "setA-" * lpad(id,2,'0')
        data_measurement = @timed load_data(joinpath(@__DIR__,"..","setA",instance);splitting=:uniform_paths)
        data = data_measurement.value
        order = id == 2 ? (:highs,:scip) : (:scip,:highs)
        for solver in order
            GC.gc()
            directory=joinpath(output_dir,String(solver))
            mkpath(directory)
            base=joinpath(directory,instance*"_run-01")
            println("START ",instance," ",solver," limit=",time_limit);flush(stdout)
            measured = @timed solve_time0(data;solver,instance,run=1,time_limit,formulation=:compact,highs_profile=:default,
                seed=1001,threads=1,log_file=base*".log",solution_file=base*"_solution.json",
                stage_observer=observe_comparison_stage)
            result = merge(measured.value,(data_seconds=data_measurement.time,
                wrapper_wall_seconds=measured.time,wrapper_julia_allocated_bytes=measured.bytes))
            write(base*".json",JSON3.write(result))
            push!(rows,result)
            append_result_csv(joinpath(output_dir,"runs.csv"),result)
            println("DONE ",instance," ",solver," seconds=",result.cpu_time_seconds,
                " mlu=",result.objective," gap=",result.gap," nodes=",result.nodes,
                " lex=",result.lex_completed_stages,"/",result.lex_total_stages);flush(stdout)
        end
        GC.gc()
    end
    return rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    output_dir = isempty(ARGS) ? joinpath(@__DIR__,"..","results","solver_comparison_"*Dates.format(Dates.now(),"yyyymmdd_HHMMSS")) : abspath(ARGS[1])
    compare_solvers(;output_dir)
end
