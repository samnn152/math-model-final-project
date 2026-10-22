# Run with: julia --project=. scripts/run_experiments.jl --instances 1 --runs 1 --time-limit 30
include(joinpath(@__DIR__, "..", "Project_Orange.jl"))

function parse_instance_selection(text)
    if occursin(':', text)
        endpoints = parse.(Int, split(text, ':'))
        length(endpoints) == 2 || error("Use --instances first:last, for example 1:20")
        return collect(endpoints[1]:endpoints[2])
    end
    return parse.(Int, split(text, ','))
end

function experiment_cli(args)
    options = Dict(
        "--instances" => "1:20", "--runs" => "10", "--run-start"=>"1", "--time-limit" => "1800",
        "--solver" => "highs", "--output" => "",
        "--threads" => "1", "--seed-base" => "1000", "--splitting" => "ecmp",
        "--highs-profile" => "auto", "--target-gap" => "0.10",
        "--formulation"=>"auto", "--compact-threshold"=>"100000",
        "--max-routes"=>"16", "--pricing-rounds"=>"40", "--pricing-time"=>"30",
        "--proof-tolerance"=>"1e-7", "--warm-start-seconds"=>"3",
        "--deadline-callback" => "true", "--max-binary-variables" => "2000000", "--lock-tolerance" => "1e-7",
    )
    if "--help" in args
        println("Time-0 lexicographic SetA experiments")
        println("Usage: julia --project=. scripts/run_experiments.jl [option value ...]")
        for key in sort(collect(keys(options)))
            println(key, " (default: ", options[key], ")")
        end
        return nothing
    end
    iseven(length(args)) || error("Each option requires a value; use --help")
    for i in 1:2:length(args)
        haskey(options,args[i]) || error("Unknown option $(args[i]); use --help")
        options[args[i]] = args[i+1]
    end
    result = run_seta_experiments(
        solver=Symbol(lowercase(options["--solver"])),
        instances=parse_instance_selection(options["--instances"]),
        runs=parse(Int, options["--runs"]),run_start=parse(Int,options["--run-start"]), time_limit=parse(Float64, options["--time-limit"]),
        output_dir=isempty(options["--output"]) ? nothing : abspath(options["--output"]), threads=parse(Int,options["--threads"]),
        seed_base=parse(Int,options["--seed-base"]), splitting=Symbol(options["--splitting"]),
        max_binary_variables=parse(Int,options["--max-binary-variables"]),
        lock_tolerance=parse(Float64,options["--lock-tolerance"]),
        highs_profile=Symbol(options["--highs-profile"]),target_gap=parse(Float64,options["--target-gap"]),
        deadline_callback=parse(Bool,options["--deadline-callback"]),
        formulation=Symbol(options["--formulation"]),compact_threshold=parse(Int,options["--compact-threshold"]),
        max_routes_per_demand=parse(Int,options["--max-routes"]),pricing_rounds=parse(Int,options["--pricing-rounds"]),
        pricing_time_limit=parse(Float64,options["--pricing-time"]),proof_tolerance=parse(Float64,options["--proof-tolerance"]),
        warm_start_seconds=parse(Float64,options["--warm-start-seconds"]),
    )
    println("Results: ", result.output_dir)
    println("Per-run CSV: ", joinpath(result.output_dir, "runs.csv"))
    println("Averages: ", joinpath(result.output_dir, "summary.csv"))
    return result
end

if abspath(PROGRAM_FILE) == @__FILE__
    experiment_cli(ARGS)
end
