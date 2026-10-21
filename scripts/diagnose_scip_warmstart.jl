# Diagnostic only: the production notebook is not modified.
notebook=abspath(joinpath(@__DIR__,"..","Project_Orange.jl"))
source=read(notebook,String)
needle="        isnothing(validation) || warm_start_lexicographic!(data,formulation,validation,stages)"
length(findall(needle,source))==1 || error("Unexpected notebook version")
replacement="""
        if solver == :scip && k > 1
            for variable in all_variables(model)
                set_start_value(variable,nothing)
            end
        else
            isnothing(validation) || warm_start_lexicographic!(data,formulation,validation,stages)
        end"""
include_string(Main,replace(source,needle=>replacement),notebook)
fixture=joinpath(@__DIR__,"..","test","fixtures","orange_subject_toy","toy")
data=load_data(fixture;splitting=:ecmp)
result=solve_time0(data;solver=:scip,formulation=:compact,time_limit=10.,instance="toy-scip-start-diagnostic")
output=abspath(only(ARGS));mkpath(dirname(output));write(output,JSON3.write(result))
println(JSON3.write((status=result.status,completed=result.lex_completed_stages,total=result.lex_total_stages,
    mlu=result.objective,optimize_seconds=result.cpu_time_seconds)))
