using Test, JSON3

@testset "Time-1 Data: directed failures, volumes and original arc indices" begin
    fixture=joinpath(@__DIR__,"fixtures","orange_subject_toy","toy")
    data=load_time01_data(fixture)
    @test axes(data.r,4)==0:1
    @test size(data.r)==(7,7,22,2)
    @test axes(data.v,2)==0:1
    @test data.v[1,0]==50 && data.v[1,1]==100
    @test data.v[2,0]==100 && data.v[2,1]==50
    @test ne(data.graphs[1])==22 && ne(data.graphs[2])==20
    @test data.periods[2].failed_arc_ids==[2,3]
    @test !has_edge(data.graphs[2],2,4)
    @test has_edge(data.graphs[2],4,2)
    @test all(iszero,data.r[:,:,3,1])
    @test all(iszero,data.r[:,:,4,1])
    @test data.r[1,6,1,0]==1 && data.r[1,6,1,1]==0
    @test data.periods[1].arc_ids==data.periods[2].arc_ids
    @test_throws ErrorException period_graph_data(data.periods[1],Set([999]),[100.,50.],1)
end

@testset "Original segment-set Budget and both-period exact objective" begin
    fixture=joinpath(@__DIR__,"fixtures","orange_subject_toy")
    data=load_time01_data(joinpath(fixture,"toy"))
    expected=JSON3.read(read(joinpath(fixture,"expected_time01.json"),String))
    @test segment_change_count([1,6],[1,5,6])==3
    @test segment_change_count([1,2,3,6],[1,3,2,6])==6
    for budget in (20,0)
        result=solve_time01_separate(merge(data,(;budget));time_limit=8.)
        reference=budget==20 ? expected.budget20.sorted_loads : expected.budget0.sorted_loads
        @test result.validated
        @test result.budget_used<=budget
        @test result.status=="Optimal"
        @test result.lex_completed_stages==result.lex_total_stages==44
        @test result.sorted_loads≈Float64.(reference) atol=1e-5
        @test result.pool_complete
    end
    columns=NamedTuple[];keys=[Set{Tuple}() for q in 1:4]
    for q in 1:4
        d=mod(q-1,2)+1;add_time01_column!(columns,keys,data,q,[data.sources[d],data.targets[d]])
    end
    # Revisited vertices are retained; repeated ordered segments cannot match binary x.
    p=add_time01_column!(columns,keys,data,1,[1,2,1,6])
    @test p>0
    @test validate_time01_selection(data,columns,[p,2,3,4]).cost==2
    @test_throws ErrorException validate_time01_selection(merge(data,(budget=0,)),columns,[p,2,3,4])
    @test_throws ErrorException add_time01_column!(columns,keys,data,1,[1,2,1,2,6])
    restricted=build_time01_master(data,columns,1,Float64[];integer=false,time_limit=1.)
    optimize!(restricted.model)
    bound=temporal_pricing_bound(data,restricted)
    @test bound.complete
    @test bound.bound<=expected.budget20.sorted_loads[1]+1e-6
    empty!(restricted.model)
    restricted_zero=build_time01_master(merge(data,(budget=0,)),columns,1,Float64[];integer=false,time_limit=1.)
    optimize!(restricted_zero.model)
    zero_bound=temporal_pricing_bound(merge(data,(budget=0,)),restricted_zero)
    @test zero_bound.complete
    @test zero_bound.bound<=expected.budget0.sorted_loads[1]+1e-6
    empty!(restricted_zero.model)
end
