using JSON3, Statistics
root = normpath(joinpath(@__DIR__, ".."))
notebook = isempty(ARGS) ? joinpath(root,"Project_Orange.jl") : abspath(ARGS[1])
label = length(ARGS) < 2 ? "current" : ARGS[2]
include_string(Main,replace(read(notebook,String),"@__DIR__" => repr(root)),notebook)

function benchmark_code(root, output_label)
    warm_up_solver(:scip; threads=1)
    rows = []
    for id in (1,2,3)
        label = "setA-" * lpad(id,2,'0')
        data_stats = @timed load_data(joinpath(root,"setA",label))
        data = data_stats.value
        GC.gc()
        build_time0_model(data; solver=:scip,time_limit=5.0,seed=1001,threads=1)
        GC.gc()
        times = Float64[]
        allocations = Int[]
        variables = 0
        constraints = 0
        for repeat in 1:5
            GC.gc()
            measured = @timed build_time0_model(data; solver=:scip,time_limit=5.0,seed=1001,threads=1)
            variables = num_variables(measured.value.model)
            constraints = num_constraints(measured.value.model;count_variable_in_set_constraints=true)
            push!(times, measured.time)
            push!(allocations, measured.bytes)
        end
        built = (time=median(times),bytes=median(allocations))
        GC.gc()
        folder = joinpath(root,"results","code_performance",output_label)
        mkpath(folder)
        solved = @timed solve_time0(data;solver=:scip,time_limit=5.0,seed=1001,threads=1,
            log_file=joinpath(folder,label*".log"),solution_file=joinpath(folder,label*".json"))
        r=solved.value
        row=(instance=label,binaries=length(data.v)*length(data.segments),variables=variables,
            constraints=constraints,data_seconds=data_stats.time,build_seconds=built.time,
            build_allocated_bytes=built.bytes,solve_wrapper_seconds=solved.time,
            optimize_seconds=r.cpu_time_seconds,status=r.status,objective=r.objective,
            lex_completed_stages=r.lex_completed_stages,lex_total_stages=r.lex_total_stages)
        push!(rows,row)
        write(joinpath(folder,"measurements.json"),JSON3.write(rows))
        println(JSON3.write(row)); flush(stdout)
    end

    return rows
end

benchmark_code(root,label)
