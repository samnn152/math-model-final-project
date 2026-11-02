"""At-most-hop walk bounds used only to prune provably expensive paths."""
function screen_suffix_bounds(costs,target,K)
    n=size(costs,1);bounds=fill(Inf,n,K+1);bounds[target,1]=0.
    for h in 1:K
        bounds[:,h+1].=bounds[:,h]
        for j in 1:n,i in 1:n
            value=costs[i,j]+bounds[j,h]
            value<bounds[i,h+1] && (bounds[i,h+1]=value)
        end
    end
    return bounds
end

"""Enumerate every simple path below a safe dual-cost threshold, or report incomplete."""
function screen_route_paths(costs,source,target,K,cutoff;max_visits=2_000_000,max_paths=100_000,deadline=Inf)
    bounds=screen_suffix_bounds(costs,target,K)
    stack=[(Int[source],0.)];paths=Vector{Int}[];visits=0
    margin=1e-9*(1+abs(cutoff))*max(1,K)
    while !isempty(stack)
        (visits>=max_visits || length(paths)>=max_paths || time()>deadline) &&
            return (;complete=false,paths,visits,remaining=length(stack))
        path,cost=pop!(stack);visits+=1;node=last(path);used=length(path)-1
        cost+bounds[node,K-used+1]>cutoff+margin && continue
        if node==target
            push!(paths,path);continue
        end
        used==K && continue
        for next in size(costs,1):-1:1
            next in path && continue
            value=cost+costs[node,next]
            isfinite(value) || continue
            value+bounds[next,K-used]<=cutoff+margin || continue
            push!(stack,(vcat(path,next),value))
        end
    end
    return (;complete=true,paths,visits,remaining=0)
end

"""Exact coefficient equality removes aliases, not distinct load vectors."""
function coefficient_signature(coefficients)
    indices,values=findnz(coefficients)
    return Tuple(zip(indices,values))
end

"""Audit all potentially improving routes against a corrected full-domain dual."""
function screen_time0_columns!(data,pool,certificate,upper;max_visits=2_000_000,max_columns=200_000,deadline=Inf)
    n=nv(data.graph);base=reshape(data.r.values*(certificate.weights./data.c),n,n)
    for j in 1:n,i in 1:n
        (i==j || data.counts[i,j]==0) && (base[i,j]=Inf)
    end
    signatures=[Set(coefficient_signature(pool.columns[p].coefficients) for p in ids) for ids in pool.by_demand]
    added=0;visits=0;retained=0
    delta=max(0.,upper-certificate.bound)
    tolerance=1e-7*(1+abs(upper)+abs(certificate.bound)+maximum(abs,certificate.beta;init=0.))*data.MaxSeg
    for d in eachindex(data.v)
        result=screen_route_paths(data.v[d].*base,data.sources[d],data.targets[d],data.MaxSeg,
            delta+certificate.beta[d]+tolerance;max_visits=max(0,max_visits-visits),max_paths=max_columns,deadline)
        visits+=result.visits
        for path in result.paths
            coefficients=sparse(sparse_route_loads(data,pool,d,path))
            signature=coefficient_signature(coefficients)
            signature in signatures[d] && continue
            length(pool.columns)>=max_columns && return (;complete=false,added,visits,retained,upper)
            p=add_route_column!(pool,data,d,path;max_routes=max_columns)
            if p>0
                push!(signatures[d],signature);added+=1
            end
        end
        retained+=length(result.paths)
        result.complete || return (;complete=false,added,visits,retained,upper)
    end
    return (;complete=true,added,visits,retained,upper)
end
