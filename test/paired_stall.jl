using Test, LinearAlgebra

@testset "Actual-ratio walk pricing preserves full-domain lower bounds" begin
    data=load_time01_data(joinpath(@__DIR__,"fixtures/orange_subject_toy/toy"))
    for budget in (0,3,20)
        adjusted=merge(data,(;budget))
        columns=NamedTuple[];keys=[Set{Tuple}() for d in data.sources]
        for d in eachindex(data.sources)
            path=[data.sources[d],data.targets[d]]
            add_time01_pair!(columns,keys,adjusted,d,path,path)
        end
        master=build_time01_pair_master(adjusted,columns,2,[1.0];time_limit=1.)
        optimize!(master.model)
        prices=time01_pair_duals(adjusted,master)
        coarse=fast_time01_pair_sweep!(columns,keys,adjusted,prices)
        exact=fast_time01_pair_sweep!(columns,keys,adjusted,prices;exact_common=true)
        @test coarse.complete && exact.complete
        @test all(exact.lower_bounds .>= coarse.lower_bounds .- 1e-7)
        for d in eachindex(data.sources)
            routes0=enumerate_test_pair_routes(adjusted,d,0)
            routes1=enumerate_test_pair_routes(adjusted,d,1)
            optimum=exhaustive_test_pair_price(routes0,routes1,prices.weights,prices.mu,budget)
            @test exact.lower_bounds[d]<=optimum+1e-6
        end
        release_pair_model!(master.model)
        @test unsafe_backend(master.model).inner==C_NULL
        release_pair_model!(master.model)
    end
end

@testset "Disposable paired HiGHS instances release native state" begin
    for i in 1:100
        model=create_time0_optimizer(:highs;time_limit=1.,seed=i,threads=1)
        @variable(model,probe>=1)
        @objective(model,Min,1.0*probe)
        install_highs_deadline!(model,1.)
        optimize!(model)
        @test objective_value(model)≈1.
        release_pair_model!(model)
        @test unsafe_backend(model).inner==C_NULL
        @test unsafe_backend(model).callback_data===nothing
        release_pair_model!(model)
    end
    GC.gc(true)
end
