# Short differential audit; no SetA optimization is launched.
include(joinpath(@__DIR__,"..","Project_Orange.jl"))

function audit_subject_toy(output)
    fixture=joinpath(@__DIR__,"..","test","fixtures","orange_subject_toy")
    data=load_data(joinpath(fixture,"toy");splitting=:ecmp)
    oracle=JSON3.read(read(joinpath(output,"exact_oracle.json"),String))
    node_index=Dict(id=>i for (i,id) in enumerate(data.node_ids))
    arc_index=Dict(id=>a for (a,id) in enumerate(data.arc_ids))
    errors=[abs(data.r[node_index[row.i],node_index[row.j],arc_index[row.arc],0]-row.value)
        for row in oracle.coefficients]
    maximum(errors) <= 1e-12 || error("Routing coefficients differ from independent exact oracle")
    rows=NamedTuple[]
    errors_found=NamedTuple[]
    for (solver,formulation) in ((:highs,:compact),(:scip,:compact),(:highs,:routes))
        name=String(solver)*"_"*String(formulation)
        result=try
            solve_time0(data;solver,formulation,time_limit=10.0,instance="official-toy-time0",
                max_routes_per_demand=1,warm_start_seconds=0.0,
                log_file=joinpath(output,name*".log"),solution_file=joinpath(output,name*"_solution.json"))
        catch exception
            message=sprint(showerror,exception)
            write(joinpath(output,name*"_error.json"),JSON3.write((solver=String(solver),formulation=String(formulation),error=message)))
            push!(errors_found,(solver=String(solver),formulation=String(formulation),error=message))
            println(name," ERROR: ",message)
            continue
        end
        write(joinpath(output,name*"_result.json"),JSON3.write(result))
        vector=Float64.(JSON3.read(result.sorted_loads_json))
        difference=maximum(abs.(vector.-Float64.(oracle.sorted_loads)))
        difference<=1e-6 || error("Wrong lexicographic vector: $name, difference=$difference")
        push!(rows,(solver=String(solver),formulation=String(formulation),status=result.status,
            termination=result.termination,mlu=result.objective,gap=result.gap,
            completed=result.lex_completed_stages,total=result.lex_total_stages,
            optimize_seconds=result.cpu_time_seconds,max_vector_error=difference,validated=result.validated))
    end
    write(joinpath(output,"julia_comparison.json"),JSON3.write((routing_max_error=maximum(errors),results=rows,errors=errors_found)))
    println(JSON3.write(rows))
end

if abspath(PROGRAM_FILE)==@__FILE__
    audit_subject_toy(abspath(only(ARGS)))
end
