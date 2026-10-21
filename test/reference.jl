using Test, JSON3

@testset "Official Orange toy: published coefficients and exact time-0 optimum" begin
    fixture=joinpath(@__DIR__,"fixtures","orange_subject_toy")
    data=load_data(joinpath(fixture,"toy");splitting=:ecmp)
    expected=JSON3.read(read(joinpath(fixture,"expected_time0.json"),String))
    arc=Dict(id=>a for (a,id) in enumerate(data.arc_ids))
    @test data.r[1,6,arc[2],0] == .5
    @test data.r[1,6,arc[6],0] == .75
    baseline=[sum(data.v[d]*data.r[data.sources[d],data.targets[d],a,0]/data.c[a]
        for d in eachindex(data.v)) for a in eachindex(data.arcs)]
    @test maximum(baseline) == .4375
    figure4=[(50*data.r[1,5,a,0]+50*data.r[5,6,a,0]+100*data.r[3,6,a,0])/data.c[a]
        for a in eachindex(data.arcs)]
    @test maximum(figure4) == .375
    @test expected.candidate_routes == [86,86]
    @test expected.combinations == 7396
    for formulation in (:compact,:routes)
        result=solve_time0(data;solver=:highs,formulation,time_limit=5.,
            max_routes_per_demand=1,warm_start_seconds=0.)
        @test result.status == "Optimal"
        @test result.validated
        @test result.lex_completed_stages == result.lex_total_stages == 22
        @test collect(JSON3.read(result.sorted_loads_json)) ≈ Float64.(expected.sorted_loads) atol=1e-6
    end
end
