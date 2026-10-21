# Run explicitly; including this script never starts the full SetA batch.
include(joinpath(@__DIR__,"..","Project_Orange.jl"))

function time01_cli(args)
    options=Dict("--instances"=>"1:20","--runs"=>"10","--time-limit"=>"3600",
        "--solver"=>"highs","--output"=>"results/time01_highs","--threads"=>"1","--seed-base"=>"1000",
        "--max-variables"=>"2000000","--max-columns"=>"100000","--formulation"=>"paired",
        "--max-pricing-variables"=>"200000","--pricing-slice"=>"2")
    if "--help" in args
        println("Original SetA, paired demand master-pricing with joint lexicographic objective and Budget; no batch starts with --help.")
        for key in sort(collect(keys(options)))
            println(key," (default: ",options[key],")")
        end
        return
    end
    iseven(length(args)) || error("Each option requires a value")
    for i in 1:2:length(args)
        haskey(options,args[i]) || error("Unknown option $(args[i])")
        options[args[i]]=args[i+1]
    end
    selection=options["--instances"]
    if occursin(':',selection)
        endpoints=parse.(Int,split(selection,':'))
        length(endpoints)==2 || error("Expected first:last")
        ids=collect(endpoints[1]:endpoints[2])
    else
        ids=parse.(Int,split(selection,','))
    end
    return run_time01_experiments(;instances=ids,runs=parse(Int,options["--runs"]),time_limit=parse(Float64,options["--time-limit"]),
        solver=Symbol(options["--solver"]),output_dir=abspath(options["--output"]),threads=parse(Int,options["--threads"]),
        seed_base=parse(Int,options["--seed-base"]),max_variables=parse(Int,options["--max-variables"]),max_columns=parse(Int,options["--max-columns"]),formulation=Symbol(options["--formulation"]),
        max_pricing_variables=parse(Int,options["--max-pricing-variables"]),pricing_slice=parse(Float64,options["--pricing-slice"]))
end

if abspath(PROGRAM_FILE)==@__FILE__
    time01_cli(ARGS)
end
