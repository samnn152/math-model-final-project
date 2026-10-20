using Test, Graphs, SparseArrays, JSON3
include(joinpath(@__DIR__, "..", "Project_Orange.jl"))

@testset "Unequal shortest-path branches and unreachable nodes" begin
    arcs = [(1,2), (1,3), (2,6), (3,4), (3,5), (4,6), (5,6)]
    g = SimpleDiGraph(7)
    for (u,v) in arcs
        add_edge!(g,u,v)
    end
    weights = sparse(first.(arcs), last.(arcs), [1.,1.,2.,1.,1.,1.,1.], 7,7)
    paths = routing_ratios(g, weights, arcs)
    ecmp = routing_ratios(g, weights, arcs; splitting=:ecmp)
    @test size(paths.r) == (7, 7, 7, 1)
    @test axes(paths.r, 4) == 0:0
    @test_throws BoundsError paths.r[1,6,1,1]
    @test_throws BoundsError paths.r[0,6,1,0]
    @test paths.counts[1,6] == 3
    @test paths.r[1,6,1,0] ≈ 1/3
    @test paths.r[1,6,2,0] ≈ 2/3
    @test ecmp.r[1,6,1,0] == 0.5
    @test ecmp.r[1,6,4,0] == 0.25
    @test all(iszero, paths.r[1,7,:,0])
    @test all(iszero, paths.r[1,1,:,0])
    @test_throws ErrorException routing_ratios(g,weights,arcs; splitting=:unknown)
end

@testset "All 20 SetA instances: JSON mapping and unit-flow conservation" begin
    for instance in 1:20
        prefix = joinpath(@__DIR__, "..", "setA", "setA-" * lpad(instance,2,'0'))
        data = load_data(prefix)
        net = JSON3.read(read(prefix * "-net.json", String))
        tm = JSON3.read(read(prefix * "-tm.json", String))
        @test data.arc_ids == [link.id for link in net.links]
        @test data.c == [link.capacity for link in net.links]
        @test data.v == [d.v[1] for d in tm.demands]
        @test data.sources == [data.node_index[Int(d.s)] for d in tm.demands]
        @test data.targets == [data.node_index[Int(d.t)] for d in tm.demands]
        @test data.MaxSeg == JSON3.read(read(prefix * "-scenario.json",String)).max_segments
        @test all(isfinite, nonzeros(data.r.values))
        @test all(x -> 0 <= x <= 1, nonzeros(data.r.values))
        n = nv(data.graph)
        incidence = sparse(vcat(first.(data.arcs),last.(data.arcs)),
            vcat(collect(eachindex(data.arcs)),collect(eachindex(data.arcs))),
            vcat(ones(length(data.arcs)),-ones(length(data.arcs))), n,length(data.arcs))
        balances = data.r.values * transpose(incidence)
        for (i,j) in data.segments
            expected = zeros(n)
            expected[i], expected[j] = 1., -1.
            @test Vector(balances[i+(j-1)*n,:]) ≈ expected atol=1e-10
        end
        println("Verified setA-", lpad(instance,2,'0'), ": ", n, " vertices, ", length(data.arcs), " arcs")
    end
end

include("optimization.jl")

