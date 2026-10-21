# Exact-rational oracle generation is separate from the JuMP implementation.
include(joinpath(@__DIR__,"..","Project_Orange.jl"))
using Test
include(joinpath(@__DIR__,"..","test","time01.jl"))

function audit_time01_reference(;output_dir=joinpath(@__DIR__,"..","results","time01_reference"))
    mkpath(output_dir)
    oracle_file=joinpath(output_dir,"oracle.json")
    run(Cmd(["python3",joinpath(@__DIR__,"audit_time01_reference.py"),"--output",oracle_file]))
    oracle=JSON3.read(read(oracle_file,String))
    fixture=joinpath(@__DIR__,"..","test","fixtures","orange_subject_toy")
    data=load_time01_data(joinpath(fixture,"toy"))
    @testset "Independent rational ECMP coefficients, both periods" begin
        for row in oracle.coefficients
            a=findfirst(==(Int(row.a)),data.arc_ids)
            i=data.periods[1].node_index[Int(row.i)]
            j=data.periods[1].node_index[Int(row.j)]
            @test data.r[i,j,a,Int(row.t)]≈Float64(row.value) atol=1e-12
        end
    end
    for budget in (20,0)
        result=solve_time01_separate(merge(data,(;budget));time_limit=8.)
        stem=joinpath(output_dir,"toy_budget$(budget)")
        write(stem*".json",JSON3.write(result))
        write(stem*"_srpaths.json",JSON3.write((srpaths=result.srpaths,)))
        if haskey(ENV,"ORANGE_CHECKER")
            scenario=JSON3.read(read(joinpath(fixture,"toy-scenario.json"),String),Dict{String,Any})
            for entry in scenario["budget"]
                entry["t"]==1 && (entry["value"]=budget)
            end
            scenario_file=stem*"_scenario.json";write(scenario_file,JSON3.write(scenario))
            command=Cmd([ENV["ORANGE_CHECKER"],"--net",joinpath(fixture,"toy-net.json"),
                "--tm",joinpath(fixture,"toy-tm.json"),"--scenario",scenario_file,"--srpaths",stem*"_srpaths.json"])
            checked=read(command,String);write(stem*"_checker.json",checked)
            report=JSON3.read(checked)
            @test report.valid
            @test report.total_cost==result.budget_used
            vector=sort(Float64[x.sat for x in report.saturations];rev=true)
            append!(vector,zeros(length(result.sorted_loads)-length(vector)))
            @test vector≈result.sorted_loads atol=1e-9
        end
    end
end

if abspath(PROGRAM_FILE)==@__FILE__
    audit_time01_reference()
end
