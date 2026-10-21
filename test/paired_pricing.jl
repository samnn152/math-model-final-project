using Test, LinearAlgebra

function enumerate_test_pair_routes(data,d,t)
    routes=NamedTuple[];n=length(data.node_ids)
    for count in 0:data.MaxSeg-1
        for middle in Iterators.product(ntuple(_->1:n,count)...)
            path=vcat(data.sources[d],collect(Int,middle),data.targets[d])
            edges=collect(zip(path,path[2:end]))
            all(i!=j && data.periods[t+1].counts[i,j]>0 for (i,j) in edges) || continue
            length(unique(edges))==length(edges) || continue
            coefficients=[sum(data.v[d,t]*data.r[i,j,a,t]/data.c[a] for (i,j) in edges) for a in eachindex(data.arcs)]
            push!(routes,(;path,edges=Set(edges),coefficients))
        end
    end
    return routes
end

function exhaustive_test_pair_price(routes0,routes1,weights,mu,budget)
    m=length(weights)÷2;minimum_cost=Inf
    for p0 in routes0,p1 in routes1
        cost=length(symdiff(p0.edges,p1.edges))
        cost<=budget || continue
        objective=dot(weights[1:m],p0.coefficients)+dot(weights[m+1:2m],p1.coefficients)+mu*cost
        minimum_cost=min(minimum_cost,objective)
    end
    return minimum_cost
end

@testset "Demand pair pricing versus exhaustive ordered-segment enumeration" begin
    data=load_time01_data(joinpath(@__DIR__,"fixtures/orange_subject_toy/toy"))
    m=length(data.arcs);n=length(data.node_ids)
    routes=[[enumerate_test_pair_routes(data,d,t) for t in 0:1] for d in eachindex(data.sources)]
    weights=[.01+mod(7a,13)/13 for a in 1:2m]
    physical=[reshape(data.periods[t+1].r.values*(weights[t*m+1:(t+1)*m]./data.c),n,n) for t in 0:1]
    for budget in (0,3,20),d in eachindex(data.sources)
        adjusted=merge(data,(;budget));mu=.13
        exact=exhaustive_test_pair_price(routes[d][1],routes[d][2],weights,mu,budget)
        price=price_time01_demand(adjusted,d,physical,mu;time_limit=2.)
        @test price.status=="OPTIMAL"
        @test price.candidate!==nothing
        @test price.candidate.cost<=budget
        @test price.candidate.objective≈exact atol=1e-6
        @test !ismissing(price.lower_bound) && price.lower_bound<=exact+1e-6
        @test price.lower_bound≈exact atol=1e-6
    end
    weights=[sin(a) for a in 1:2m];mu=-.07;budget=3;d=1
    physical=[reshape(data.periods[t+1].r.values*(weights[t*m+1:(t+1)*m]./data.c),n,n) for t in 0:1]
    exact=exhaustive_test_pair_price(routes[d][1],routes[d][2],weights,mu,budget)
    price=price_time01_demand(merge(data,(;budget)),d,physical,mu;time_limit=2.)
    @test price.candidate.objective≈exact atol=1e-6
    @test price.lower_bound≈exact atol=1e-6
    floor=data.MaxSeg*sum(data.v[d,t-1]*min(0.,minimum(physical[t])) for t in 1:2)+min(0.,2data.MaxSeg*mu)
    @test floor<=exact+1e-8
    @test_throws ErrorException build_time01_pair_pricer(data,1,physical,0.;max_variables=1)
end

@testset "Paired master Budget and conservative missing-column correction" begin
    data=load_time01_data(joinpath(@__DIR__,"fixtures/orange_subject_toy/toy"))
    columns=NamedTuple[];keys=[Set{Tuple}() for d in data.sources]
    for d in eachindex(data.sources)
        path=[data.sources[d],data.targets[d]]
        @test add_time01_pair!(columns,keys,data,d,path,path)>0
    end
    @test add_time01_pair!(columns,keys,data,1,[1,6],[1,6])==0
    changed=add_time01_pair!(columns,keys,data,1,[1,6],[1,5,6])
    @test columns[changed].cost==3
    validation=validate_time01_pairs(data,columns,[changed,2])
    @test validation.cost==3
    @test_throws ErrorException validate_time01_pairs(merge(data,(budget=0,)),columns,[changed,2])
    master=build_time01_pair_master(data,columns,1,Float64[];time_limit=1.)
    optimize!(master.model)
    prices=time01_pair_duals(data,master)
    @test time01_pair_bound(prices,prices.floors)<=.375+1e-6
    lower_bounds=copy(prices.floors)
    for d in eachindex(data.sources)
        price=price_time01_demand(data,d,prices.physical,prices.mu;time_limit=2.)
        @test !ismissing(price.lower_bound)
        lower_bounds[d]=max(lower_bounds[d],price.lower_bound-1e-7*(1+abs(price.lower_bound)))
    end
    @test time01_pair_bound(prices,lower_bounds)<=.375+1e-6
    @test time01_pair_bound(prices,lower_bounds)>=time01_pair_bound(prices,prices.floors)-1e-8
    empty!(master.model)
end

@testset "Paired search: original toy, numerical prefix and exact singleton domain" begin
    fixture=joinpath(@__DIR__,"fixtures/orange_subject_toy")
    data=load_time01_data(joinpath(fixture,"toy"))
    oracle=JSON3.read(read(joinpath(fixture,"expected_time01.json"),String))
    for budget in (20,0)
        result=solve_time01(merge(data,(;budget));time_limit=2.)
        expected=Float64.((budget==20 ? oracle.budget20 : oracle.budget0).sorted_loads)
        @test result.validated && result.budget_used<=budget
        @test result.formulation=="paired_demand_master_pricing"
        @test result.lower_bound<=expected[1]+1e-6
        @test result.objective>=expected[1]-1e-6
        @test result.pricing_calls>0
        @test result.cpu_time_seconds≈result.lp_optimize_seconds+result.pricing_optimize_seconds+result.mip_optimize_seconds atol=1e-7
        for j in 1:result.lex_completed_stages
            @test sum(result.sorted_loads[1:j])≈sum(expected[1:j]) atol=1e-4
        end
        @test result.status!="Optimal" || result.lex_completed_stages==44
    end
    singleton=merge(data,(MaxSeg=1,budget=0))
    columns=NamedTuple[];keys=[Set{Tuple}() for d in data.sources]
    for d in eachindex(data.sources)
        path=[data.sources[d],data.targets[d]]
        add_time01_pair!(columns,keys,singleton,d,path,path)
    end
    expected=sort(validate_time01_pairs(singleton,columns,[1,2]).loads;rev=true)
    result=solve_time01(singleton;time_limit=5.)
    @test result.status=="Optimal"
    @test result.lex_completed_stages==result.lex_total_stages==44
    @test result.sorted_loads≈expected atol=1e-6
    @test result.budget_used==0
end

@testset "Paired LP dominates matching marginal pools; exclusion pricing is distinct" begin
    data=load_time01_data(joinpath(@__DIR__,"fixtures/orange_subject_toy/toy"))
    adjusted=merge(data,(budget=3,))
    period_columns=NamedTuple[];period_keys=[Set{Tuple}() for q in 1:4]
    pair_columns=NamedTuple[];pair_keys=[Set{Tuple}() for d in 1:2]
    for d in 1:2
        choices=[[data.sources[d],data.targets[d]],[data.sources[d],5,data.targets[d]]]
        for t in 0:1,path in choices
            add_time01_column!(period_columns,period_keys,adjusted,t*2+d,path)
        end
        for p0 in choices,p1 in choices
            add_time01_pair!(pair_columns,pair_keys,adjusted,d,p0,p1)
        end
    end
    separate=build_time01_master(adjusted,period_columns,1,Float64[];integer=false,time_limit=1.)
    paired=build_time01_pair_master(adjusted,pair_columns,1,Float64[];time_limit=1.)
    optimize!(separate.model);optimize!(paired.model)
    @test objective_value(paired.model)>=objective_value(separate.model)-1e-7
    prices=time01_pair_duals(adjusted,paired)
    unrestricted=price_time01_demand(adjusted,1,prices.physical,prices.mu;time_limit=2.)
    c=unrestricted.candidate
    excluded=[(paths=(c.path0,c.path1),)]
    diversified=price_time01_demand(adjusted,1,prices.physical,prices.mu;time_limit=2.,exclude_pairs=excluded)
    @test diversified.candidate!==nothing
    oldsets=[Set(zip(path,path[2:end])) for path in (c.path0,c.path1)]
    newsets=[Set(zip(path,path[2:end])) for path in (diversified.candidate.path0,diversified.candidate.path1)]
    @test newsets!=oldsets
    @test diversified.candidate.objective>=unrestricted.candidate.objective-1e-6
    empty!(separate.model);empty!(paired.model)
end
