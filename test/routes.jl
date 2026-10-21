using Test

@testset "Equivalent route model and restricted-pool honesty" begin
    data=time0_demo_data()
    compact=solve_time0(data;formulation=:compact,time_limit=5.0)
    routes=solve_time0(data;formulation=:routes,time_limit=5.0)
    @test routes.status == compact.status == "Optimal"
    @test collect(JSON3.read(routes.sorted_loads_json)) ≈ collect(JSON3.read(compact.sorted_loads_json)) atol=1e-6
    @test routes.lex_completed_stages == 4
    @test routes.binary_variables < routes.potential_compact_variables
    @test keys(routes) == keys(compact)
    directory=mktempdir()
    restricted=solve_time0(data;formulation=:routes,time_limit=5.0,
        max_routes_per_demand=1,pricing_rounds=1,warm_start_seconds=0.0,
        log_file=joinpath(directory,"continued.log"))
    lines=readlines(joinpath(directory,"continued_stages.csv"))
    header=split(first(lines),',')
    stage_index=findfirst(==("stage"),header)
    cycle_index=findfirst(==("cycle"),header)
    retry_rows=[split(line,',') for line in lines[2:end]]
    @test any(row -> parse(Int,strip(row[stage_index],'"')) == 2 && parse(Int,strip(row[cycle_index],'"')) > 1,retry_rows)
    rm(directory;recursive=true)
    @test restricted.status == "Optimal"
    @test restricted.lex_completed_stages == 4
    @test restricted.binary_variables > length(data.v)
    @test restricted.bound_scope == "global"
    @test collect(JSON3.read(restricted.sorted_loads_json)) ≈ [1.,.5,.5,0.] atol=1e-6
    # Even an initial pool cap of one must expand rather than stop at the already optimal MLU.
    pool=initial_route_pool(data)
    lp=solve_route_lp!(data,pool,2,[1.0+1e-7];remaining=1.0,rounds=1,max_routes=1)
    @test lp.bound <= 1.5+1e-7
    @test !route_pool_complete(data,pool)
    ranks=fill(big(0),length(data.v));hops=ones(Int,length(data.v))
    expanded=expand_route_pool!(data,pool,ranks,hops;max_routes=10)
    @test expanded.added > 0
    @test route_pool_complete(data,pool)
    @test expand_route_pool!(data,pool,ranks,hops;max_routes=10).added == 0

end

@testset "Pricing matches exhaustive small-route enumeration" begin
    data=time0_demo_data()
    for weights in ([0.,0.,0.,0.],[.1,.2,.3,.4],[0.,1.,1.,1.])
        priced=minimum_segment_routes(data,weights)
        @test priced.complete
        for d in eachindex(data.v)
            source,target=data.sources[d],data.targets[d]
            candidates=[[source,target]]
            for w in vertices(data.graph)
                w in (source,target) && continue
                data.counts[source,w]>0 && data.counts[w,target]>0 || continue
                push!(candidates,[source,w,target])
            end
            costs=[sum(sum(weights[a]*data.r[path[h],path[h+1],a,0]/data.c[a]
                for a in eachindex(data.arcs)) for h in 1:length(path)-1) for path in candidates]
            @test priced.route_costs[d] ≈ minimum(costs) atol=1e-10
            @test priced.paths[d] in candidates
        end
    end
    incomplete=minimum_segment_routes(data,zeros(length(data.arcs));deadline=-Inf)
    @test !incomplete.complete
end

@testset "Persistent expansion covers longer routes without duplicates" begin
    graph=SimpleDiGraph(4)
    arcs=[(i,j) for i in 1:4 for j in 1:4 if i != j]
    for (i,j) in arcs
        add_edge!(graph,i,j)
    end
    routing=routing_ratios(graph,sparse(first.(arcs),last.(arcs),ones(length(arcs)),4,4),arcs)
    data=(;graph,v=[1.0],c=ones(length(arcs)),arcs,sources=[1],targets=[4],
        MaxSeg=3,r=routing.r,counts=routing.counts)
    pool=initial_route_pool(data)
    ranks=[big(0)];hops=[1]
    for cycle in 1:10
        expand_route_pool!(data,pool,ranks,hops;max_routes=10,per_demand=1)
    end
    expected=Set([(1,4),(1,2,4),(1,3,4),(1,2,3,4),(1,3,2,4)])
    @test pool.keys[1] == expected
    @test length(pool.columns) == 5
    @test route_pool_complete(data,pool)
    @test hops[1] == 3
    @test expand_route_pool!(data,pool,ranks,hops;max_routes=10).exhausted
end
