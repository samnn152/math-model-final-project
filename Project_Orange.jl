### A Pluto.jl notebook ###
# v1.0.4

using Markdown
using InteractiveUtils

# ╔═╡ 7fdb9545-2175-4cf3-862c-ccc4ebd1d627
begin
    using JSON3
    using Graphs
    using SparseArrays
    using JuMP
    import HiGHS
    import SCIP
    using Dates
    const ORANGE_MOI = JuMP.MOI
    const ORANGE_SOLVER_LOCK = ReentrantLock()
end

# ╔═╡ 7e06044c-4f17-4753-8d29-54fea385e727
struct NetworkData{G<:Graphs.AbstractGraph}
    graph::G

    # Node information
    id_to_vertex::Dict{Int, Int}
    vertex_to_id::Vector{Int}
    vertex_name::Vector{String}

    # Link information, indexed by Julia endpoints (u,v)
    link_id::Dict{Tuple{Int, Int}, Int}
    metric::Dict{Tuple{Int, Int}, Float64}
    capacity::Dict{Tuple{Int, Int}, Float64}
end

# ╔═╡ fee9dcd1-c6f5-46e7-9546-24ba4209efb2
# Canonical key for an edge.
# For a directed graph:   (u,v)
# For an undirected graph: (min(u,v), max(u,v))
edge_key(directed::Bool, u::Int, v::Int) =
    directed ? (u, v) : (u <= v ? (u, v) : (v, u))

# ╔═╡ 7ba74f02-ab39-4cce-a008-e456bccf8332
function json_to_graph(filename::AbstractString)
    data = JSON3.read(read(filename, String))

    # ---------- Check top-level JSON structure ----------
    required_top = ("directed", "multigraph", "nodes", "links")
    missing_top = [k for k in required_top if !haskey(data, k)]

    isempty(missing_top) ||
        error("Missing top-level JSON field(s): $(join(missing_top, ", "))")

    directed = Bool(data["directed"])
    multigraph = Bool(data["multigraph"])

    multigraph &&
        error("This converter uses Graphs.jl simple graphs and does not accept multigraph=true.")

    nodes = data["nodes"]
    links = data["links"]

    # ---------- Nodes ----------
    isempty(nodes) && error("The JSON file contains no nodes.")

    for (i, node) in enumerate(nodes)
        haskey(node, "id") ||
            error("Node $i has no 'id' field.")
        haskey(node, "name") ||
            error("Node $i has no 'name' field.")
    end

    vertex_to_id = Int[Int(node["id"]) for node in nodes]

    length(unique(vertex_to_id)) == length(vertex_to_id) ||
        error("Node IDs must be unique.")

    id_to_vertex = Dict(
        json_id => julia_vertex
        for (julia_vertex, json_id) in enumerate(vertex_to_id)
    )

    vertex_name = String[String(node["name"]) for node in nodes]

    # ---------- Graph ----------
    n = length(nodes)

    g = if directed
        SimpleDiGraph(n)
    else
        SimpleGraph(n)
    end

    # ---------- Link attributes ----------
    link_id = Dict{Tuple{Int, Int}, Int}()
    metric = Dict{Tuple{Int, Int}, Float64}()
    capacity = Dict{Tuple{Int, Int}, Float64}()

    seen_link_ids = Set{Int}()

    for (i, link) in enumerate(links)
        for field in ("id", "from", "to", "metric", "capacity")
            haskey(link, field) ||
                error("Link $i has no '$field' field.")
        end

        e_id = Int(link["id"])
        from_id = Int(link["from"])
        to_id = Int(link["to"])

        e_id in seen_link_ids &&
            error("Duplicate link ID: $e_id")
        push!(seen_link_ids, e_id)

        haskey(id_to_vertex, from_id) ||
            error("Link $e_id refers to unknown node ID $from_id.")

        haskey(id_to_vertex, to_id) ||
            error("Link $e_id refers to unknown node ID $to_id.")

        u = id_to_vertex[from_id]
        v = id_to_vertex[to_id]

        # Graphs.jl SimpleGraph/SimpleDiGraph does not allow parallel edges.
        add_edge!(g, u, v) ||
            error("Duplicate/parallel link between node IDs $from_id and $to_id.")

        key = edge_key(directed, u, v)

        link_id[key] = e_id
        metric[key] = Float64(link["metric"])
        capacity[key] = Float64(link["capacity"])
    end

    return NetworkData(
        g,
        id_to_vertex,
        vertex_to_id,
        vertex_name,
        link_id,
        metric,
        capacity,
    )
end

# ╔═╡ 41836f74-0f1f-4e99-a4fc-7be3c2f2cc55
function edge_attributes(network::NetworkData, u::Int, v::Int)
    key = edge_key(is_directed(network.graph), u, v)

    haskey(network.link_id, key) ||
        error("There is no edge $u → $v in the graph.")

    return (
        id = network.link_id[key],
        metric = network.metric[key],
        capacity = network.capacity[key],
    )
end

# ╔═╡ aa5cf923-9654-4b58-8085-2b66ea3aca47
begin
    function attribute_matrix(network::NetworkData, attribute::Symbol)
        values = if attribute === :metric
            network.metric
        elseif attribute === :capacity
            network.capacity
        else
            error("attribute must be :metric or :capacity")
        end
    
        directed = is_directed(network.graph)
        n = nv(network.graph)
    
        I = Int[]
        J = Int[]
        V = Float64[]
    
        for ((u, v), value) in values
            push!(I, u)
            push!(J, v)
            push!(V, value)
    
            if !directed && u != v
                push!(I, v)
                push!(J, u)
                push!(V, value)
            end
        end
    
        return sparse(I, J, V, n, n)
    end
    
    metric_matrix(network::NetworkData) =
        attribute_matrix(network, :metric)
    
    capacity_matrix(network::NetworkData) =
        attribute_matrix(network, :capacity)
end

# ╔═╡ b58aa673-0039-483f-abd0-337c9b7e0a68
json_file = joinpath(@__DIR__, "setA/setA-09-net.json")

# ╔═╡ 72cbbb3d-6002-491b-9559-4d0955e077fb
network = json_to_graph(json_file)

# ╔═╡ caa9cb28-0c1a-43be-97be-0b54fb06489c
g = network.graph

# ╔═╡ db1c3609-d65a-4e95-a215-815052cc27a1
(
    graph_type = typeof(g),
    directed = is_directed(g),
    number_of_vertices = nv(g),
    number_of_edges = ne(g),
)

# ╔═╡ de136f32-2133-4e18-abef-fbb42cffd537
begin
    json_node_id = 0
    julia_vertex = network.id_to_vertex[json_node_id]

    (
        json_id = json_node_id,
        julia_vertex = julia_vertex,
        name = network.vertex_name[julia_vertex],
    )
end

# ╔═╡ a8bfaf8b-a886-48db-b27b-f68fbdfcc871
begin
    u = network.id_to_vertex[0]
    v = network.id_to_vertex[24]

    edge_attributes(network, u, v)
end

# ╔═╡ 0286942e-2224-4bad-b162-f3db59b674cb
W = metric_matrix(network)

# ╔═╡ fc38f677-cab0-4d6a-8ee2-2cd5360d1107
struct RoutingRatios <: AbstractArray{Float64,4}
    values::SparseMatrixCSC{Float64,Int}
    n::Int
end

# ╔═╡ c6571fd9-6161-4010-83b9-878be5565d4f
begin
    Base.size(r::RoutingRatios) = (r.n, r.n, size(r.values, 2), 1)
    Base.axes(r::RoutingRatios) = (
        Base.OneTo(r.n), Base.OneTo(r.n), Base.OneTo(size(r.values, 2)), 0:0,
    )

    function Base.getindex(r::RoutingRatios, i::Int, j::Int, a::Int, t::Int)
        checkbounds(r, i, j, a, t)
        return r.values[i + (j - 1) * r.n, a]
    end

    function Base.setindex!(r::RoutingRatios, value, i::Int, j::Int, a::Int, t::Int)
        checkbounds(r, i, j, a, t)
        r.values[i + (j - 1) * r.n, a] = value
        return value
    end
end

# ╔═╡ 2cdaf3dd-0a25-4ce2-9da9-4ee017ca9a1b
md"""
# Project Orange

## Network: JSON file → Graphs.jl graph

The network section is based on `json_to_graph_pluto_v2.jl`.
This notebook will contain the project model and verification.

The network reader accepts a JSON file with the same structure as
`setA-09-net.json` and converts it into a `Graphs.jl` graph.

Expected JSON structure:

- `directed`: `true` or `false`
- `multigraph`: must be `false`
- `nodes`: objects containing `id` and `name`
- `links`: objects containing `id`, `from`, `to`, `metric`, and `capacity`

The JSON node identifiers may start at 0 (as in the example file). They are
mapped explicitly to Julia/Graphs.jl vertex numbers `1:n`.
"""

# ╔═╡ 705b5e90-5ef4-4285-a46a-4ef4fb0dff01
md"""
## Data structure

`graph` is the actual `Graphs.jl` graph.

The other fields keep the information that is not stored by a
`SimpleGraph` or `SimpleDiGraph`.
"""

# ╔═╡ dda5b3e7-2a6c-4df2-9fdc-e0784b4c3b94
md"""
### Function: `edge_key(directed, u, v)`

**Purpose:** give each link a consistent dictionary key.

**Input:** graph direction and two Julia vertex indices. **Output:** `(u,v)` for a
directed graph; `(min(u,v),max(u,v))` for an undirected graph. Thus an undirected
link has the same key in either direction. The graph reader and attribute lookup
use this key to retrieve the same link.
"""

# ╔═╡ ae531c1a-a653-41bf-879c-799723f2a086
md"""
## Conversion function

The function checks the schema, creates the graph, and preserves the
node/link attributes.
"""

# ╔═╡ 43d0094d-56ff-4e00-9863-1e590a500fbd
md"""
### Function: `json_to_graph(filename)`

**Purpose:** turn the network JSON file into a graph while retaining its attributes.

**Input:** the network file path. **Output:** a `NetworkData` object containing the
graph, mappings between JSON IDs and Julia vertices, node names, and dictionaries
of link IDs, metrics, and capacities. It checks required fields, unique IDs,
known endpoints, and duplicate links. This lecturer-provided converter rejects
`multigraph=true`; the separate batch loader below checks actual duplicate arcs.
"""

# ╔═╡ f09af42c-d81b-4f31-8b7b-9f240c81be6b
md"""
## Helper functions

`edge_attributes(network,u,v)` returns the JSON attributes of a link,
where `u` and `v` are Julia vertex numbers.

`metric_matrix(network)` creates a sparse matrix that can, for example,
be supplied as the distance matrix to shortest-path algorithms.
"""

# ╔═╡ 38301175-d029-4afc-b53e-0daa01a907c7
md"""
### Function: `edge_attributes(network, u, v)`

**Purpose:** look up one physical link's attributes.

**Input:** a `NetworkData` object and two Julia vertex indices. **Output:** a named
tuple containing the link's JSON ID, metric, and capacity. It uses `edge_key` to
find the correct dictionary entry and reports an error if the link is absent.
"""

# ╔═╡ b5ec0ef2-7107-4b1c-8baa-ee686077eb0a
md"""
### Functions: `attribute_matrix`, `metric_matrix`, `capacity_matrix`

`attribute_matrix(network, attribute)` converts either the `:metric` or
`:capacity` dictionary into a sparse vertex-by-vertex matrix. Entry `[u,v]`
contains that attribute for the physical link. Undirected links are entered in
both directions; absent links remain zero.

`metric_matrix(network)` calls it with `:metric`; `capacity_matrix(network)`
calls it with `:capacity`. Their input is `NetworkData`, and their output is a
sparse matrix. The metric matrix supplies arc lengths to shortest-path algorithms.
"""

# ╔═╡ 63d45e27-6c5c-4755-9b94-4a7531c85599
md"""
## Read a file

Put the JSON file in the same directory as this notebook and change only
the filename below when needed.
"""

# ╔═╡ ee9d2d3e-6d88-4bf0-8038-1e0f9a2cdbee
md"""
## Examples

The JSON node ID `0` is not a Graphs.jl vertex number. Use
`network.id_to_vertex` to convert JSON IDs to Julia vertices.
"""

# ╔═╡ 2ca6ec67-4e36-4426-aa29-072d06b57cda
md"""
### Function: `edge_attributes(network, u, v)`

**Purpose:** look up one physical link's attributes.

**Input:** a `NetworkData` object and two Julia vertex indices. **Output:** a named
tuple containing the link's JSON ID, metric, and capacity. It uses `edge_key` to
find the correct dictionary entry and reports an error if the link is absent.
"""

# ╔═╡ 670cc8d4-0867-4838-a7a3-321eab3ce633
md"""
For example, a shortest-path computation using `metric` as the arc length is:

```julia
source = network.id_to_vertex[0]
sp = dijkstra_shortest_paths(g, source, W)
```

The resulting `sp.dists[v]` gives the shortest-path distance from `source`
to Julia vertex `v`.
"""

# ╔═╡ ae4b5be8-dc73-4f32-9009-900a20ddf276
md"""
# Data

This section reads the three JSON files for the network
selected above and calculates the model parameters at time 0. Each numbered step
has an executable cell and a displayed result. Helper functions are defined
separately; none is defined inside another function.

The parameters are `r[i,j,a,t]`, `c[a]`, `v0[d]`, and `MaxSeg`.
The routing array uses time index `0`, matching the mathematical notation.
"""

# ╔═╡ 07fc53b5-d72d-4135-ac04-ddd147c641df
md"""
## Data structure

`RoutingRatios` stores routing fractions sparsely with access as `r[i,j,a,t]`.
Vertices and arcs use indices starting at 1. Pair `(i,j)` is stored at matrix
row `i + (j-1)*n`, with arc `a` in column `a`.
The fourth axis is `0:0`, so the initial period is accessed as `r[i,j,a,0]`.
`size(r,4) == 1` means one stored period, while `axes(r,4) == 0:0` gives its
actual time label. Accessing time 1 raises a bounds error until later steps
implement that period.
"""

# ╔═╡ 5d0089ff-b7cd-449a-8b90-dfb0bed95170
md"""
### Array methods: `size`, `axes`, `getindex`, `setindex!`

These methods let the sparse storage behave like the mathematical array.
`size(r)` returns `(n,n,m,1)`; `axes(r,4)` returns `0:0`, the actual time label.
Reading `r[i,j,a,t]` calls `getindex`; assigning it calls `setindex!`. Both check
the four indices and map `(i,j)` to sparse row `i+(j-1)*n`, with arc `a` as the
column. Time 1 is rejected because only time 0 has been calculated. These methods
store and retrieve coefficients; they do not calculate routing paths.
"""

# ╔═╡ 60d722a6-4a74-478a-9a0c-0c8ee621c30a
md"""
## Helper functions

These definitions are reused by the numbered calculations below.
"""

# ╔═╡ 3fb349a8-71d0-4824-b6eb-d5ba20c6de4e
md"""
### Function: `decimal_rational(x)`

**Purpose:** express a metric's displayed decimal representation as an exact fraction.

**Input:** one numeric metric. **Output:** a `Rational{BigInt}`. For example,
`decimal_rational(0.25)` returns `1//4`. It separates digits and any scientific
notation exponent, then divides by the appropriate power of ten. This operates
on `string(x)` after JSON parsing; it does not recover the original JSON token.
`integer_metric_matrix` uses the fractions to choose a common integer scale.
"""

# ╔═╡ 23bcabc4-a9ea-4675-b4bd-45e1993e3863
function decimal_rational(x)
    mantissa, exponent = let parts = split(lowercase(string(x)), 'e')
        (parts[1], length(parts) == 2 ? parse(Int,parts[2]) : 0)
    end
    parts = split(mantissa, '.')
    digits = length(parts) == 2 ? length(parts[2]) : 0
    numerator = parse(BigInt, join(parts))
    power = exponent - digits
    return power >= 0 ? (numerator * big(10)^power)//big(1) : numerator//big(10)^(-power)
end

# ╔═╡ f70e64a7-360f-4c04-ace3-cbef7b206201
md"""
### Function: `integer_metric_matrix(arcs, metric, n)`

**Purpose:** build shortest-path weights that support exact equality checks.

**Input:** directed endpoint pairs, their metric values in the same order, and
the vertex count. **Output:** `(weights, scale)`, where `weights` is a sparse
`Int128` matrix. It computes the least common multiple of the fractions'
denominators and multiplies every metric by this common scale. For metrics
`0.25` and `0.5`, scale 4 produces weights 1 and 2. A common positive scale
preserves shortest paths. The function also checks the integer range.
"""

# ╔═╡ eef04c78-4a67-4ec8-921d-d4b486f24cb2
function integer_metric_matrix(arcs, metric, n)
    exact = decimal_rational.(metric)
    scale = foldl(lcm, denominator.(exact); init=big(1))
    scaled = [numerator(w * scale) for w in exact]
    maximum(scaled; init=big(0)) * n * 3 < typemax(Int128) ||
        error("Scaled metrics exceed Int128 range")
    weights = sparse(first.(arcs), last.(arcs), Int128.(scaled), n, n)
    return weights, scale
end

# ╔═╡ 666bb559-ace9-46c3-9e73-a2cf9e8cf27b
md"""
### Function: `all_pairs_shortest_data(g, weights)`

**Purpose:** obtain the distances and path counts needed for the routing formula.

**Input:** a graph and its positive arc-weight matrix. **Output:**
`(distances, counts)`. Dijkstra runs once from every source `i`, with
`allpaths=true`; row `i` stores distances and numbers of shortest paths to each
vertex `j`. `counts[i,j] == 0` identifies an unreachable pair. The diagonal count
is one, representing the empty path used as a prefix or suffix. Distances use
the units of `weights`, so scaled input produces scaled distances.
"""

# ╔═╡ 68972105-6d4c-4f91-815b-2e5749098ced
function all_pairs_shortest_data(g, weights)
    n = nv(g)
    distances = fill(typemax(eltype(weights)), n, n)
    counts = zeros(n, n)
    for i in 1:n
        state = dijkstra_shortest_paths(g, i, weights; allpaths=true)
        distances[i, :] .= state.dists
        counts[i, :] .= state.pathcounts
        counts[i, i] = 1.0
    end
    return distances, counts
end

# ╔═╡ fffc1e57-fe39-423e-9816-a157cc62bcc3
md"""
### Function: `ratios_from_shortest_data(g, weights, arcs, distances, counts)`

**Purpose:** calculate the four-index coefficients `r[i,j,a,t]` from previously
computed shortest-path information, without running Dijkstra again.

**Input:** the graph, weights, JSON-ordered arc endpoints, distances, and counts.
**Output:** a sparse-backed `RoutingRatios` array with time axis `0:0`.

With the default `splitting=:uniform_paths`, each arc `(u,v)` is checked against
the shortest-distance equality. Eligible arcs receive
`counts[i,u] * counts[v,j] / counts[i,j]`; all others remain zero. Diagonal and
unreachable pairs are zero. The optional `:ecmp` branch instead propagates unit
flow towards each destination and splits it equally between shortest-path next
hops. The numbered Data calculation uses the default handout formula.
"""

# ╔═╡ 292a9848-3359-4acc-998c-f9323ee75cde
function ratios_from_shortest_data(g, weights, arcs, distances, counts; splitting=:uniform_paths)
    splitting in (:uniform_paths, :ecmp) || error("Unknown splitting convention: $splitting")
    n = nv(g)
    r = RoutingRatios(spzeros(n*n, length(arcs)), n)
    if splitting == :uniform_paths
        for (a, (u, v)) in enumerate(arcs), j in 1:n, i in 1:n
            if i != j && counts[i,u] > 0 && counts[v,j] > 0 && counts[i,j] > 0 &&
                distances[i,u] + weights[u,v] + distances[v,j] == distances[i,j]
                r[i,j,a,0] = counts[i,u] * counts[v,j] / counts[i,j]
            end
        end
    else
        outgoing = [[a for (a, (u, _)) in enumerate(arcs) if u == node] for node in 1:n]
        for j in 1:n
            order = sortperm(distances[:,j]; rev=true)
            next_arcs = [[a for a in outgoing[u] if counts[u,j] > 0 &&
                weights[arcs[a]...] + distances[arcs[a][2],j] == distances[u,j]] for u in 1:n]
            for i in 1:n
                (i == j || counts[i,j] == 0) && continue
                flow = zeros(n)
                flow[i] = 1.0
                for u in order
                    isempty(next_arcs[u]) && continue
                    share = flow[u] / length(next_arcs[u])
                    for a in next_arcs[u]
                        r[i,j,a,0] = share
                        flow[arcs[a][2]] += share
                    end
                end
            end
        end
    end
    return r
end

# ╔═╡ 6122b1a4-46f5-4e0a-b4f3-cfa91dd7dbf8
md"""
### Function: `routing_ratios(g, weights, arcs)`

**Purpose:** provide a convenience call when shortest-path data has not yet been computed.

**Input:** the graph, weights, and ordered physical arcs; optional `splitting`
selects the routing convention. **Output:** a named tuple with `.r`, `.distances`,
and `.counts`. It first calls `all_pairs_shortest_data`, then
`ratios_from_shortest_data`. The small worked example uses this function;
the main Data section calls the two operations separately to display each stage.
"""

# ╔═╡ 14fc12c7-d155-4fdd-92b8-c4727f993b3a
function routing_ratios(g, weights, arcs; splitting=:uniform_paths)
    distances, counts = all_pairs_shortest_data(g, weights)
    r = ratios_from_shortest_data(g, weights, arcs, distances, counts; splitting)
    return (; r, distances, counts)
end

# ╔═╡ 76bae8ac-9d90-45cf-a106-b2b89f257141
md"""
### Batch-loading helper

`load_data` combines the same operations for later SetA experiments. The worked
Data section below executes each operation in its own cell instead of hiding
the whole calculation behind this function.
"""

# ╔═╡ 134cd3a7-b362-4faf-91c7-f7505987a468
md"""
### Function: `load_data(prefix)`

**Purpose:** prepare one complete instance in a single call for batch experiments.

**Input:** a prefix such as `joinpath(@__DIR__, "setA", "setA-01")`; optional
`splitting` defaults to `:uniform_paths`. It reads the corresponding `-net.json`,
`-tm.json`, and `-scenario.json` files, validates the graph and demands, calculates
routing fractions, and identifies reachable candidate segments.

**Output:** a named tuple containing the graph, ID mappings, arc metrics,
capacities `.c`, demand endpoints, initial volumes `.v`, `.MaxSeg`, `.r`,
distances, counts, and reachable `.segments`. It prepares only time 0.
This function is for repeated experiments; the numbered Data cells below perform
the operations explicitly so their intermediate results remain visible.
"""

# ╔═╡ 3ec9a21c-de5f-4d98-914f-1f8a52a0fe14
"""Load `<prefix>-net.json`, `-tm.json`, and `-scenario.json` at time 0.

Vertices, arcs, and demands use Julia indices 1:n in JSON list order.
`node_ids`, `arc_ids`, and `demand_ids` retain their external identifiers.
`v[d]` is JSON v[0] (Julia v[1]); `c[a]` is capacity, not metric.
"""
function load_data(prefix::AbstractString; splitting=:uniform_paths)
    net = JSON3.read(read(prefix * "-net.json", String))
    tm = JSON3.read(read(prefix * "-tm.json", String))
    scenario = JSON3.read(read(prefix * "-scenario.json", String))
    net.directed || error("Expected a directed graph")
    # Some SetA files declare multigraph=true without containing parallel arcs.
    node_ids = Int[node.id for node in net.nodes]
    n = length(node_ids)
    n > 0 && length(unique(node_ids)) == n || error("Empty or duplicate nodes")
    node_index = Dict(id => i for (i,id) in enumerate(node_ids))
    g = SimpleDiGraph(n)
    arcs = Tuple{Int,Int}[]
    arc_ids = Int[]
    c = Float64[]
    metric = Float64[]
    for link in net.links
        u, v = node_index[Int(link.from)], node_index[Int(link.to)]
        u != v && add_edge!(g, u, v) || error("Self-loop or duplicate arc")
        push!(arcs, (u,v))
        push!(arc_ids, Int(link.id))
        push!(c, Float64(link.capacity))
        push!(metric, Float64(link.metric))
    end
    length(unique(arc_ids)) == length(arc_ids) || error("Duplicate arc IDs")
    all(x -> isfinite(x) && x > 0, c) || error("Capacities must be finite and positive")
    all(x -> isfinite(x) && x > 0, metric) || error("Metrics must be finite and positive")
    weights, scale = integer_metric_matrix(arcs, metric, n)
    sources = Int[]
    targets = Int[]
    v = Float64[]
    tm.num_time_slots >= 1 || error("Missing time 0")
    for demand in tm.demands
        length(demand.v) == tm.num_time_slots || error("Demand horizon mismatch")
        push!(sources, node_index[Int(demand.s)])
        push!(targets, node_index[Int(demand.t)])
        push!(v, Float64(demand.v[1]))
    end
    all(x -> isfinite(x) && x >= 0, v) || error("Invalid demand volume")
    MaxSeg = Int(scenario.max_segments)
    MaxSeg >= 2 || error("MaxSeg must be at least 2")
    routing = routing_ratios(g, weights, arcs; splitting)
    segments = [(i,j) for i in 1:n for j in 1:n if i != j && routing.counts[i,j] > 0]
    all(routing.counts[s,t] > 0 for (s,t) in zip(sources,targets)) || error("Unreachable demand")
    distances = [
        routing.counts[i, j] > 0 ?
        Float64(BigFloat(routing.distances[i, j]) / BigFloat(scale)) : Inf
        for i in 1:n, j in 1:n
    ]

    return (
        graph = g,
        node_ids = node_ids,
        node_index = node_index,
        arcs = arcs,
        arc_ids = arc_ids,
        arc_index = Dict(id => a for (a, id) in enumerate(arc_ids)),
        metric = metric,
        c = c,
        demand_ids = collect(0:length(v)-1),
        sources = sources,
        targets = targets,
        v = v,
        MaxSeg = MaxSeg,
        r = routing.r,
        distances = distances,
        counts = routing.counts,
        segments = segments,
        splitting = splitting,
        time = 0,
    )
end

# ╔═╡ 639dd9b5-2c73-4976-a91d-0ca342e9a730
md"""
## 1. Read the three JSON files

The network path is `json_file`, selected in the lecturer's section above.
The other two files must have the same instance prefix.
"""

# ╔═╡ aa9b5be4-6deb-478e-95dc-0e70af0f1c06
data_files = (
    net = json_file,
    tm = replace(json_file, r"-net\.json$" => "-tm.json"),
    scenario = replace(json_file, r"-net\.json$" => "-scenario.json"),
)

# ╔═╡ d323ce08-754c-48a3-99d8-69ced264e569
begin
    net_json = JSON3.read(read(data_files.net, String))
    tm_json = JSON3.read(read(data_files.tm, String))
    scenario_json = JSON3.read(read(data_files.scenario, String))
    (
        network_file = basename(data_files.net),
        traffic_file = basename(data_files.tm),
        scenario_file = basename(data_files.scenario),
        time_periods_in_input = tm_json.num_time_slots,
    )
end

# ╔═╡ 0a74323a-829b-4252-abf4-74e2eb4d378b
md"""
## 2. Network parameters and capacities

Reuse the graph `g` and node mapping `network.id_to_vertex` built above.
Arc indices follow JSON list order, while `arc_ids` retains the original IDs.

```math
\omega(a)=\texttt{net.links[a].metric},\qquad
c(a)=\texttt{net.links[a].capacity}.
```

The output displays the first five links with their metrics and capacities.
"""

# ╔═╡ 0cdf5c45-8acc-4ed7-b8fd-fcc8c55a7064
begin
    node_ids = network.vertex_to_id
    arc_ids = Int[link.id for link in net_json.links]
    arcs = [
        (network.id_to_vertex[Int(link.from)], network.id_to_vertex[Int(link.to)])
        for link in net_json.links
    ]
    metric = Float64[link.metric for link in net_json.links]
    c = Float64[link.capacity for link in net_json.links]
    all(x -> isfinite(x) && x > 0, metric) || error("Invalid metrics")
    all(x -> isfinite(x) && x > 0, c) || error("Invalid capacities")
    [
        (arc_id=arc_ids[a], from_id=node_ids[arcs[a][1]],
         to_id=node_ids[arcs[a][2]], metric=metric[a], capacity=c[a])
        for a in 1:min(5, length(arcs))
    ]
end

# ╔═╡ 6619e810-da86-474f-ba23-eace1ea0e41c
md"""
## 3. Shortest-path distances and counts

Metrics determine shortest paths. Integer scaling avoids rounding errors when
checking equal path lengths. All metrics use the same positive scale, so the
shortest paths are preserved. `shortest_distances` below is in original units;
`scaled_distances` is used for exact comparisons.
"""

# ╔═╡ 6c2929c9-48ef-4131-ab8d-d7556cfa2a5f
(routing_weights, metric_scale) = integer_metric_matrix(arcs, metric, nv(g))

# ╔═╡ d3e7277b-763b-49d8-8c0d-62447a67da7d
(scaled_distances, sigma) = all_pairs_shortest_data(g, routing_weights)

# ╔═╡ 9eb9dfc3-9864-4aff-a57e-9e55cf1a80e0
shortest_distances = [
    sigma[i, j] > 0 ? Float64(BigFloat(scaled_distances[i, j]) / BigFloat(metric_scale)) : Inf
    for i in vertices(g), j in vertices(g)
]

# ╔═╡ 4d947c2c-0b50-466d-9531-11ae949b7475
md"""
## 4. Calculate r[i,j,a,t] at time 0

The default calculation implements the shortest-path counting formula in
`calculating_r.pdf`, Section 2. Let the nominal directed network be

```math
G(0) = (V,A(0)).
```

For each ordered pair of vertices, Dijkstra computes the distance and path count:

```math
d_{ij}(0) = \min_{P\in\mathcal{P}_{ij}}\sum_{a\in P}\omega(a),
\qquad
\sigma_{ij}(0) = \left|\left\{P\in\mathcal{P}_{ij}:
\sum_{a\in P}\omega(a)=d_{ij}(0)\right\}\right|.
```

Here, the arc weight is the network JSON field `metric`; it is distinct from
capacity. For an arc, the routing fraction is

```math
a=(u,v),\qquad
r(i,j,a,0)=
\begin{cases}
\displaystyle\frac{\sigma_{iu}(0)\,\sigma_{vj}(0)}{\sigma_{ij}(0)},
& \sigma_{ij}(0)>0\ \text{and}\ d_{iu}(0)+\omega(a)+d_{vj}(0)=d_{ij}(0),\\[6pt]
0, & \text{otherwise}.
\end{cases}
```

The distance equality identifies arcs belonging to shortest paths. The numerator
counts shortest paths using the arc; the denominator counts all shortest paths
between the pair. Diagonal pairs are assigned zero because the model uses
segments with distinct endpoints. An empty path has count one when needed as a
prefix or suffix in the numerator.

In the code, `distances` stores scaled distances and `counts` stores the path
counts. The common positive weight scale preserves the distance equality.

`:uniform_paths` selects this formula and is the default. The optional `:ecmp`
mode instead divides incoming flow equally among shortest-path next hops at each
router; that is a separate convention and can give different coefficients.

"""

# ╔═╡ c11a6811-2307-4114-959f-33e003248779
r = ratios_from_shortest_data(g, routing_weights, arcs, scaled_distances, sigma)

# ╔═╡ 2abd4a34-78d3-41b8-af9a-4eb8de6f436b
(
    dimensions = size(r),
    time_indices = axes(r, 4),
    nonzero_coefficients = nnz(r.values),
    convention = :uniform_paths,
)

# ╔═╡ 42025609-6da1-4f30-b179-2834cfda5f84
md"""
## 5. Initial demand volumes

```math
\nu(d,0)=\texttt{tm.demands[d].v[1]}.
```

`v0[d]` stores this initial volume. Source and target IDs are converted to Julia
vertices. The output shows the first five demands, using original JSON IDs.
"""

# ╔═╡ af77aedb-41fd-44ce-8903-7c6b9a30eeee
begin
    demand_ids = collect(0:length(tm_json.demands)-1)
    demand_sources = [network.id_to_vertex[Int(d.s)] for d in tm_json.demands]
    demand_targets = [network.id_to_vertex[Int(d.t)] for d in tm_json.demands]
    all(length(d.v) == tm_json.num_time_slots for d in tm_json.demands) || error("Demand horizon mismatch")
    v0 = Float64[d.v[1] for d in tm_json.demands]
    all(x -> isfinite(x) && x >= 0, v0) || error("Invalid demand volumes")
    all(sigma[i,j] > 0 for (i,j) in zip(demand_sources,demand_targets)) || error("Unreachable demand")
    [
        (demand_id=demand_ids[d], source_id=node_ids[demand_sources[d]],
         target_id=node_ids[demand_targets[d]], volume_at_time_0=v0[d])
        for d in 1:min(5, length(v0))
    ]
end

# ╔═╡ 8285c789-4544-4e0b-ab93-06d50117a7fe
md"""
## 6. Maximum number of segments

```math
\mathrm{MaxSeg}=\texttt{scenario.max\_segments}.
```

This counts segments, including the first and last. There are no interventions
or reconfiguration budget constraints at time 0.
"""

# ╔═╡ a8a1398c-12d5-4487-ae3c-11ffb035aae6
begin
    MaxSeg = Int(scenario_json.max_segments)
    MaxSeg >= 2 || error("MaxSeg must be at least 2")
    MaxSeg
end

# ╔═╡ 57a38ca7-5918-4ddf-b7b3-cb9f162b7e06
md"""
## 7. Display routing coefficients for the first demand

For the direct segment between its source and target, display every used arc.
`fraction` is `r[i,j,a,0]`; `traffic` is its product with the initial demand
volume. These are Data calculations before optimizing the waypoint choices.
"""

# ╔═╡ d89ccb2f-9276-4840-b7b2-c4dd42c2f791
let
    d, t = 1, 0
    i, j = demand_sources[d], demand_targets[d]
    (
        demand_id = demand_ids[d],
        source_id = node_ids[i],
        target_id = node_ids[j],
        initial_volume = v0[d],
        shortest_path_count = sigma[i,j],
        coefficients = [
            (arc_id=arc_ids[a], from_id=node_ids[arcs[a][1]],
             to_id=node_ids[arcs[a][2]], capacity=c[a],
             fraction=r[i,j,a,t], traffic=v0[d]*r[i,j,a,t])
            for a in eachindex(arcs) if r[i,j,a,t] > 0
        ],
    )
end

# ╔═╡ 23b5c53d-1c91-4827-891c-5ffe3278746a
md"""
## 8. Verify a fraction by hand

Consider four vertices with unit-weight arcs `(1,2)`, `(1,3)`, `(2,4)`, `(3,4)`.
There are exactly two shortest paths from 1 to 4: `1 → 2 → 4` and `1 → 3 → 4`.
Only the first uses arc 1, so

```math
r(1,4,a_1,0)=\frac{\sigma_{11}(0)\sigma_{24}(0)}{\sigma_{14}(0)}
=\frac{1\cdot1}{2}=\frac12.
```

The next cell constructs that graph, computes the coefficient, and checks the
result against one half.
"""

# ╔═╡ 90f96945-670a-46ea-b65a-0f8adcabee5f
let
    arcs = [(1, 2), (1, 3), (2, 4), (3, 4)]
    graph = SimpleDiGraph(4)
    for (u, v) in arcs
        add_edge!(graph, u, v)
    end
    weights = sparse(first.(arcs), last.(arcs), ones(Int, 4), 4, 4)
    result = routing_ratios(graph, weights, arcs)
    r = result.r
    i, j, a, t = 1, 4, 1, 0
    @assert r[i, j, a, t] == 0.5

    (
        shortest_path_count = result.counts[i, j],
        expected_fraction = 1 / 2,
        calculated_fraction = r[i, j, a, t],
        matches = r[i, j, a, t] == 0.5,
    )
end

# ╔═╡ f72ae162-d95f-493b-9b6f-6df649fd1c7b
md"""
## Model-ready Data

The fields below collect the parameters already computed in the preceding cells.
`segments` excludes unreachable pairs and pairs with identical endpoints.
"""

# ╔═╡ 80be73dd-dbbc-4e1f-abdd-990290d138e7
model_data = (
    graph=g, node_ids=node_ids, node_index=network.id_to_vertex,
    arcs=arcs, arc_ids=arc_ids,
    arc_index=Dict(id => a for (a,id) in enumerate(arc_ids)),
    metric=metric, c=c, demand_ids=demand_ids,
    sources=demand_sources, targets=demand_targets, v=v0, MaxSeg=MaxSeg,
    r=r, distances=shortest_distances, counts=sigma,
    segments=[(i,j) for i in vertices(g) for j in vertices(g) if i != j && sigma[i,j] > 0],
    splitting=:uniform_paths, time=0,
)

# ╔═╡ 7e724cb5-ebfd-46eb-96db-c3338fd9682c
(
    vertices=nv(g), arcs=length(arcs), demands=length(v0),
    MaxSeg=MaxSeg, time_indices=axes(r,4),
)

# ╔═╡ 01d94b4b-9344-40bc-a6d5-9a606214527a
md"""
# Mathematical model: time 0

This model uses the Data prepared above. Let V be the vertices, A the physical
arcs, D the demands, and S the reachable ordered pairs of distinct vertices.
A segment is a pair in S, not necessarily a physical arc. Define

```math
x_{ij}^{d,0}\in\{0,1\},\qquad
\lambda_a=\frac{1}{c(a)}\sum_{d\in D}\sum_{(i,j)\in S}
\nu(d,0)\,r(i,j,a,0)\,x_{ij}^{d,0}.
```

**Flow conservation and segment limit:**

```math
\sum_{j:(i,j)\in S}x_{ij}^{d,0}-\sum_{j:(j,i)\in S}x_{ji}^{d,0}
=\begin{cases}1&i=s_d,\\-1&i=t_d,\\0&\text{otherwise},\end{cases}
\qquad
\sum_{(i,j)\in S}x_{ij}^{d,0}\le K,\quad K=\mathrm{MaxSeg}.
```

To obtain a single segment path, incoming and outgoing degrees are each at most
one. Continuous waypoint positions exclude directed cycles:

```math
0\le q_{di}\le K,\qquad q_{d,s_d}=0,\qquad
q_{dj}\ge q_{di}+1-(K+1)(1-x_{ij}^{d,0}).
```

For selected segments, positions increase by at least one; summing these
inequalities around a cycle is impossible. Removing a repeated-waypoint cycle
cannot increase any arc load, so simple segment paths suffice for this objective.
No budget or intervention constraint applies at time 0.

**Original objective:** sort all physical arc loads in decreasing order, then
minimize that vector lexicographically:

```math
\lambda_{(1)}\ge\cdots\ge\lambda_{(m)},\quad m=|A|,
\qquad\operatorname{lexmin}(\lambda_{(1)},\ldots,\lambda_{(m)}).
```

"""

# ╔═╡ 1dbfe41e-f2c5-48e9-ba14-0d3dfbac8953
md"""
## Sequential formulation of the lexicographic objective

Let the sum of the k largest loads be

```math
F_k(\lambda)=\sum_{h=1}^{k}\lambda_{(h)}.
```

Lexicographically minimizing the sorted loads is equivalent to minimizing
F1, then F2 while holding F1 optimal, and so on. At the first differing position,
the earlier partial sums agree, so both comparisons give the same ordering.
For each k, the following linear epigraph represents the top-k sum:

```math
F_k(\lambda)=\min_{\theta_k\ge0,\ e_{ak}\ge0}
\left(k\theta_k+\sum_{a\in A}e_{ak}\right),
\qquad e_{ak}\ge\lambda_a-\theta_k.
```

Stage 1 uses the simpler equivalent constraints lambda_a <= z and minimizes z.
The final stage minimizes the sum of all loads. The other stages use this epigraph.
After proving stage k optimal, retain the constraint

```math
k\theta_k+\sum_{a\in A}e_{ak}\le F_k^*+\varepsilon.
```

The exact mathematical model has epsilon = 0. The implementation records a
numerical lock tolerance (default 1e-7), alongside the selected solver's feasibility and objective
tolerances. Results are optimal within those tolerances, not symbolic exact arithmetic.
This uses sequential objectives, not a weighted approximation to the load vector.
The procedure stops at the first stage that is not certified optimal.

"""

# ╔═╡ 7fa918df-698f-4109-a3f1-f3610ff0089d
md"""
### Function: `build_time0_model` — Build the time-0 routing model

Receives prepared Data, solver settings, and a model-size limit. Returns the JuMP model, segment-choice variables, load expressions, and waypoint positions. It adds the constraints written above and supplies direct routing as a feasible initial solution. Only reachable segments are created. The size check runs before allocating the binary variables.
"""

# ╔═╡ 3a0b9ef2-b4da-4d67-9774-a7f6dd0be497
md"""
### Function: `orange_solver_version`

Returns the native SCIP or HiGHS version, rather than the Julia wrapper version. Saved with each run, stage, solution, config, environment record and summary so comparisons identify the actual engine.
"""

# ╔═╡ 6a30c8cc-722c-4d0e-8f52-708b285aa477
function orange_solver_version(solver::Symbol)
    solver == :scip && return string(SCIP.SCIP_versionnumber())
    solver == :highs && return unsafe_string(HiGHS.Highs_version())
    error("Unknown solver $solver; choose :scip or :highs")
end

# ╔═╡ ad946052-f7b2-4283-af1e-6c1a5e9adc76
md"""
### Function: `create_time0_optimizer`

Creates the selected direct JuMP backend, SCIP by default. Applies the requested seed, thread limits, zero relative objective gap, absolute gap 1e-8 and feasibility tolerance 1e-7 with solver-specific parameter names. SCIP uses randomization/randomseedshift, limits/gap and limits/absgap; HiGHS uses random_seed, mip_rel_gap and mip_abs_gap. The model equations are unchanged. Ordinary SCIP.jl optimize! uses SCIPsolve, not concurrent SCIPsolveConcurrent: thread options are caps on available SCIP/LP threading, not a promise of parallel branch-and-bound. Default single-thread runs make the initial comparison reproducible.
"""

# ╔═╡ 62e7cb29-8eb2-4f7e-80e2-e3a5e4c59685
function create_time0_optimizer(solver::Symbol; time_limit, seed, threads, console=false)
    solver in (:scip,:highs) || error("Unknown solver $solver; choose :scip or :highs")
    if solver == :scip
        1 <= threads <= 64 || error("SCIP thread limit must be between 1 and 64")
        model = direct_model(SCIP.Optimizer())
        set_optimizer_attribute(model,"randomization/randomseedshift",seed)
        set_optimizer_attribute(model,"parallel/maxnthreads",threads)
        set_optimizer_attribute(model,"lp/threads",threads)
        set_optimizer_attribute(model,"limits/gap",0.0)
        set_optimizer_attribute(model,"limits/absgap",1e-8)
        set_optimizer_attribute(model,"numerics/feastol",1e-7)
        set_optimizer_attribute(model,"display/verblevel",console ? 4 : 0)
        SCIP.SCIPsetMessagehdlrQuiet(unsafe_backend(model),console ? 0 : 1)
    else
        model = direct_model(HiGHS.Optimizer())
        set_optimizer_attribute(model,"threads",threads)
        set_optimizer_attribute(model,"random_seed",seed)
        set_optimizer_attribute(model,"mip_rel_gap",0.0)
        set_optimizer_attribute(model,"mip_abs_gap",1e-8)
        set_optimizer_attribute(model,"mip_feasibility_tolerance",1e-7)
        set_optimizer_attribute(model,"log_to_console",console)
    end
    set_time_limit_sec(model,Float64(time_limit))
    return model
end

# ╔═╡ 572e721a-0b40-483d-9cca-699697e967b8
md"""
### Function: `set_stage_log!`

Starts a fresh native solver log for one lexicographic stage. SCIP uses its message-handler logfile API and separately suppresses console output; setting display verbosity to zero would also erase useful file output. HiGHS uses its log_file option. Both retain progress, bounds and termination information even when console=false.
"""

# ╔═╡ 34cb53e6-9d18-4e01-bb93-87d4b00b6191
function set_stage_log!(model, solver::Symbol, path; console=false)
    if !isempty(path)
        mkpath(dirname(abspath(path)))
        isfile(path) && rm(path)
    end
    if solver == :scip
        # Keep normal verbosity for the file; quiet suppresses console output only.
        set_optimizer_attribute(model,"display/verblevel",console || !isempty(path) ? 4 : 0)
        SCIP.SCIPsetMessagehdlrLogfile(unsafe_backend(model),isempty(path) ? C_NULL : abspath(path))
        SCIP.SCIPsetMessagehdlrQuiet(unsafe_backend(model),console ? 0 : 1)
    else
        set_optimizer_attribute(model,"log_file",isempty(path) ? "" : abspath(path))
        set_optimizer_attribute(model,"log_to_console",console)
    end
    return nothing
end

# ╔═╡ 1935636c-86ae-4568-b106-eb860a63b493
md"""
### Function: `close_stage_log!`

Closes and flushes the native log after optimize! so the final stage log is immediately readable. Log setup and closing lie outside the optimize! timer.
"""

# ╔═╡ a1c4e846-ca92-4d46-b073-8d8ccfa2fa05
function close_stage_log!(model, solver::Symbol)
    if solver == :scip
        SCIP.SCIPsetMessagehdlrLogfile(unsafe_backend(model),C_NULL)
    else
        set_optimizer_attribute(model,"log_file","")
    end
    return nothing
end

# ╔═╡ b562a1eb-49cd-480b-8a74-9d445145a150
md"""
### Function: `set_stage_time_limit!`

Sets the solver-specific clock limit for the remaining wall-time budget. HiGHS receives remaining seconds directly. For incremental SCIP solves, its current solving-clock origin is added to the remaining allowance. The external sum of optimize! wall times remains the authoritative shared budget, so the budget is never restarted at 1800 seconds for a new stage.
"""

# ╔═╡ ca0d5bf6-340c-48b8-89ce-23ffef2eda46
function set_stage_time_limit!(model, solver::Symbol, remaining)
    # SCIP can retain a solving clock across incremental solves; account for its origin.
    clock_origin = solver == :scip ? SCIP.SCIPgetSolvingTime(unsafe_backend(model)) : 0.0
    solver_limit = max(0.0,clock_origin) + remaining
    set_time_limit_sec(model,solver_limit)
    return solver_limit
end

# ╔═╡ 72e9296a-3367-402d-9c66-88bf4026d4fa
function build_time0_model(data; solver=:scip, time_limit=1800.0, seed=1, threads=1,
        max_binary_variables=2_000_000, log_file="", console=false)
    isfinite(time_limit) && time_limit > 0 || error("time_limit must be positive and finite")
    threads >= 1 || error("threads must be positive")
    0 <= seed <= typemax(Int32) || error("Invalid solver random seed")
    data.time == 0 || error("This model supports time 0 only")
    n, m, k = nv(data.graph), length(data.arcs), length(data.v)
    segments = data.segments
    p = length(segments)
    binary_variables = k * p
    binary_variables <= max_binary_variables || error(
        "MODEL_SIZE_LIMIT: $binary_variables binary variables exceed limit $max_binary_variables")
    model = create_time0_optimizer(solver; time_limit, seed, threads, console)
    isempty(log_file) || set_stage_log!(model,solver,log_file; console)
    @variable(model, x[1:k, 1:p], Bin)
    @variable(model, z >= 0)
    @variable(model, 0 <= position[1:k, 1:n] <= data.MaxSeg)
    outgoing = [[s for (s,(i,j)) in enumerate(segments) if i == u] for u in 1:n]
    incoming = [[s for (s,(i,j)) in enumerate(segments) if j == u] for u in 1:n]
    for d in 1:k
        source, target = data.sources[d], data.targets[d]
        source != target || error("Demand $d has identical source and destination")
        for u in 1:n
            rhs = u == source ? 1 : (u == target ? -1 : 0)
            @constraint(model, sum(x[d,s] for s in outgoing[u]) -
                sum(x[d,s] for s in incoming[u]) == rhs)
            @constraint(model, sum(x[d,s] for s in outgoing[u]) <= 1)
            @constraint(model, sum(x[d,s] for s in incoming[u]) <= 1)
        end
        @constraint(model, sum(x[d,s] for s in 1:p) <= data.MaxSeg)
        fix(position[d,source], 0.0; force=true)
        for (s,(i,j)) in enumerate(segments)
            @constraint(model, position[d,j] >= position[d,i] + 1 -
                (data.MaxSeg + 1) * (1 - x[d,s]))
        end
    end
    segment_index = Dict(pair => s for (s,pair) in enumerate(segments))
    segment_row = Dict(i + (j-1)*n => s for (s,(i,j)) in enumerate(segments))
    loads = [AffExpr(0.0) for a in 1:m]
    ratio_rows = rowvals(data.r.values)
    ratio_values = nonzeros(data.r.values)
    for a in 1:m
        for entry in nzrange(data.r.values, a)
            s = get(segment_row, ratio_rows[entry], 0)
            s == 0 && continue
            for d in 1:k
                coefficient = ratio_values[entry] * data.v[d] / data.c[a]
                iszero(coefficient) || add_to_expression!(loads[a], coefficient, x[d,s])
            end
        end
        @constraint(model, loads[a] <= z)
    end
    @objective(model, Min, 1.0 * z)
    # Direct segments give a feasible initial routing, even when their paths split.
    direct_loads = zeros(m)
    for d in 1:k
        direct = segment_index[(data.sources[d],data.targets[d])]
        for s in 1:p
            set_start_value(x[d,s], s == direct ? 1.0 : 0.0)
        end
        for u in 1:n
            set_start_value(position[d,u], u == data.targets[d] ? 1.0 : 0.0)
        end
        for a in 1:m
            direct_loads[a] += data.v[d] * data.r[data.sources[d],data.targets[d],a,0] / data.c[a]
        end
    end
    set_start_value(z, maximum(direct_loads; init=0.0))
    return (; model, x, z, position, loads, segments, binary_variables)
end

# ╔═╡ 919891f0-8ace-459b-a20b-af51bfc1a72b
md"""
### Function: `validate_time0_solution` — Independently check an incumbent

Receives Data and a solved formulation. Reads selected segment variables, reconstructs each demand route, and checks integrality, endpoints, segment limits, repeated waypoints, branching, and disconnected cycles. It recomputes physical arc loads from the selected routes and Data coefficients. Returns the routes, selected segments, load vector, and maximum load; a failed check raises an error.
"""

# ╔═╡ 0371b231-be81-4b68-b3cc-a59153b78de6
function validate_time0_solution(data, formulation; tolerance=1e-5)
    model, x, segments = formulation.model, formulation.x, formulation.segments
    primal_status(model) == ORANGE_MOI.FEASIBLE_POINT || error("No feasible incumbent to validate")
    n, m, k = nv(data.graph), length(data.arcs), length(data.v)
    arc_loads = zeros(m)
    routes = NamedTuple[]
    selected_segments = Vector{Int}[]
    for d in 1:k
        selected = Int[]
        for s in eachindex(segments)
            value_x = value(x[d,s])
            abs(value_x - round(value_x)) <= tolerance || error("Nonintegral route variable")
            value_x > 0.5 && push!(selected,s)
        end
        length(selected) <= data.MaxSeg || error("Segment limit violated")
        current = data.sources[d]
        path = [current]
        used = Set{Int}()
        while current != data.targets[d]
            choices = [s for s in selected if segments[s][1] == current]
            length(choices) == 1 || error("Route is disconnected or branches")
            s = only(choices)
            s in used && error("Cycle in segment route")
            push!(used,s)
            current = segments[s][2]
            current in path && error("Repeated waypoint")
            push!(path,current)
        end
        length(used) == length(selected) || error("Disconnected cycle or extra segments")
        for s in selected
            i,j = segments[s]
            for a in 1:m
                arc_loads[a] += data.v[d] * data.r[i,j,a,0] / data.c[a]
            end
        end
        push!(routes, (d=data.demand_ids[d], t=0, w=data.node_ids[path[2:end-1]]))
        push!(selected_segments,selected)
    end
    maximum_load = maximum(arc_loads; init=0.0)
    z_value = value(formulation.z)
    maximum_load <= z_value + tolerance * max(1.0, abs(z_value)) || error("Arc load exceeds objective")
    return (; valid=true, maximum_load, arc_loads, routes, selected_segments)
end

# ╔═╡ 8feaf3ce-4168-4e1f-b74a-28c2629331ed
md"""
### Function: `add_lexicographic_stage!` — Set one lexicographic objective

Receives a formulation and stage index k. Stage 1 minimizes z. Intermediate stages add a threshold and excess variables for the sum of the k largest arc loads. The last stage minimizes the sum of all loads directly. Returns the objective expression and any new variables. It modifies the existing model so earlier locks remain in force.
"""

# ╔═╡ c72df640-0622-495a-bb90-e25dabf05398
function add_lexicographic_stage!(formulation, k, total_arcs)
    model = formulation.model
    if k == 1
        expression = 1.0 * formulation.z
        @objective(model, Min, expression)
        return (; k, expression, threshold=nothing, excess=nothing)
    elseif k == total_arcs
        expression = sum(formulation.loads)
        @objective(model, Min, expression)
        return (; k, expression, threshold=nothing, excess=nothing)
    end
    threshold = @variable(model, lower_bound=0.0, base_name="threshold_$k")
    excess = @variable(model, [1:total_arcs], lower_bound=0.0, base_name="excess_$k")
    for a in 1:total_arcs
        @constraint(model, excess[a] >= formulation.loads[a] - threshold)
    end
    expression = k * threshold + sum(excess)
    @objective(model, Min, expression)
    return (; k, expression, threshold, excess)
end

# ╔═╡ 0de9cc87-9690-4d83-9801-79895e5c17df
md"""
### Function: `warm_start_lexicographic!` — Reuse the preceding feasible routing

Receives Data, the formulation, a validated route, and all stage definitions. Sets initial values for segment choices, waypoint positions, z, and threshold/excess variables using that route. This supplies a feasible starting candidate for the next stage; it does not replace optimization or certify optimality.
"""

# ╔═╡ 882f34a4-64c8-4f50-81e3-216f3a682ae6
function warm_start_lexicographic!(data, formulation, validation, stages)
    for d in eachindex(data.v)
        selected = Set(validation.selected_segments[d])
        for s in eachindex(formulation.segments)
            set_start_value(formulation.x[d,s], s in selected ? 1.0 : 0.0)
        end
        for u in vertices(data.graph)
            set_start_value(formulation.position[d,u], 0.0)
        end
        current = data.sources[d]
        depth = 0
        while current != data.targets[d]
            s = only([s for s in selected if formulation.segments[s][1] == current])
            current = formulation.segments[s][2]
            depth += 1
            set_start_value(formulation.position[d,current], depth)
        end
    end
    sorted_loads = sort(validation.arc_loads; rev=true)
    set_start_value(formulation.z, validation.maximum_load)
    for stage in stages
        isnothing(stage.threshold) && continue
        threshold = sorted_loads[stage.k]
        set_start_value(stage.threshold, threshold)
        for a in eachindex(validation.arc_loads)
            set_start_value(stage.excess[a], max(0.0, validation.arc_loads[a]-threshold))
        end
    end
    return nothing
end

# ╔═╡ 509862d6-b196-4c68-9b78-095105ade572
md"""
### Function: `experiment_gap` — Calculate a scalar bound gap

Receives an incumbent U and a lower bound L. Returns 1-L/U, or missing if either value is absent. When both are zero within numerical tolerance, returns zero. A materially inconsistent bound raises an error. This helper applies to a scalar stage or to the separately reported MLU; it does not define a gap for an entire lexicographic vector.
"""

# ╔═╡ 9441b09a-b55a-4693-bb71-5fd48be058a5
function experiment_gap(incumbent, lower_bound)
    (ismissing(incumbent) || ismissing(lower_bound)) && return missing
    if iszero(incumbent)
        return abs(lower_bound) <= 1e-8 ? 0.0 : missing
    end
    gap = 1.0 - lower_bound / incumbent
    gap >= -1e-5 || error("Lower bound exceeds incumbent")
    return max(0.0, gap)
end

# ╔═╡ 732eb7a7-7aa7-4ca1-8302-05a9d4d6cbda
md"""
### Function: `solve_time0_serial` — Solve the complete lexicographic problem

Receives one instance and run settings. Solves stages in order, locks each certified stage optimum, and stops at the first unfinished stage or when the shared optimize! budget is exhausted. Each call to optimize! is timed separately; reading, construction, and validation are excluded. Validates every available incumbent and preserves the latest validated route if a later solve finds none. Returns one result row and writes stage logs and the solution when paths are supplied. Optimal means all stages finished, within the recorded solver and lock tolerances.
"""

# ╔═╡ 4ad642fe-2c86-4d74-979a-b48d657f2917
md"""
## Execute a small lexicographic example

Direct routing gives sorted loads `(1, 0.8, 0, 0)`. An intermediate waypoint
changes this to `(1, 0.5, 0.5, 0)`. Both have MLU 1, but the second vector is
lexicographically better. The executable cells below show the computed vector,
status, number of completed stages, and time spent inside optimize!.

"""

# ╔═╡ 78a0ae6d-a64b-4f25-abb2-40bd06ab6e26
md"""
### Function: `time0_demo_data`

Returns Data for two demands on a five-node graph. One demand forces a maximum load of 1. The other can use a direct link with load 0.8 or two links with loads 0.5 each. The lexicographic optimum is therefore the sorted vector (1,0.5,0.5,0). This example distinguishes the full objective from MLU alone.
"""

# ╔═╡ 07d9e8b5-b949-4581-b3ca-a13eac2f28f4
function time0_demo_data()
    # The first demand fixes MLU at 1; the second can improve its lower-ranked loads.
    arcs = [(1,2),(3,5),(3,4),(4,5)]
    graph = SimpleDiGraph(5)
    for (u,v) in arcs
        add_edge!(graph,u,v)
    end
    weights = sparse(first.(arcs),last.(arcs),[1,1,1,1],5,5)
    routing = routing_ratios(graph,weights,arcs)
    segments = [(i,j) for i in 1:5 for j in 1:5 if i != j && routing.counts[i,j] > 0]
    return (graph=graph,node_ids=collect(0:4),arc_ids=collect(0:3),
        arcs=arcs,c=[1.0,1.25,2.0,2.0],v=[1.0,1.0],sources=[1,3],targets=[2,5],
        demand_ids=[0,1],MaxSeg=2,r=routing.r,segments=segments,time=0,splitting=:uniform_paths)
end

# ╔═╡ 43a769d5-c2db-451a-a2b1-dc3852794675
lex_demo_data = time0_demo_data()

# ╔═╡ ae31ff5d-31d1-4080-bd5e-a1ad45d11609
md"""
# Numerical experiments and logs

For one repetition, the shared solve-time budget is

```math
T_{\mathrm{solve}}=\sum_{k\ \mathrm{attempted}}T_k\le1800\ \mathrm{seconds},
\qquad T_{\mathrm{remaining}}=1800-\sum_{h<k}T_h.
```

Only time enclosing `optimize!` is accumulated. This is elapsed wall time, called
CPU time in the assignment; it is not process CPU usage. JSON reading, routing
preprocessing, model construction, validation, and output writing are excluded.
Each stage is given the remaining budget. Small solver-stop overhead can exceed
the requested limit slightly. The batch runner warms up its selected solver outside the measured SetA runs.

A lexicographic objective is a vector and has no single ordinary relative MIP gap.
Therefore the output retains the entire sorted load vector and records two kinds
of scalar bounds without confusing them:

```math
\mathrm{gap}_{\mathrm{MLU}}=1-\frac{L_1}{U_1},\qquad
\mathrm{gap}_{\mathrm{stage}\ k}=1-\frac{L_k}{U_k}.
```

`objective`, `lower_bound`, and `gap` refer to the MLU component (stage 1).
`stage_objective`, `stage_lower_bound`, and `stage_gap` refer to the last attempted
stage. `sorted_loads_json` stores the full objective vector. `Optimal` requires
all m stages to finish. A zero MLU gap can coexist with `Not Optimal` when later
lexicographic stages remain unfinished. State this distinction in the report.
A missing incumbent gives missing objective and gap; it is not called Infeasible.

For R repetitions, report averages over available observations and their counts:

```math
\bar y=\frac{1}{|I_y|}\sum_{r\in I_y}y_r,\qquad
I_y=\{r:\ y_r\ \text{is available}\}.
```

The README requests R = 10. `summary.csv` includes sample counts so incomplete
runs cannot silently become zeros or appear to be ten successful observations.
A full 20-instance, ten-repeat run has up to 100 hours of solve-time allowance.

"""

# ╔═╡ c0816744-3cf8-4925-a207-e993582610b8
md"""
### Function: `csv_field` — Encode one CSV value

Receives a scalar value and returns a quoted CSV field, escaping embedded quotes. Missing values become empty fields rather than artificial zeros.
"""

# ╔═╡ a48c15c8-a4b1-4d69-982f-81ffbb19ac45
function csv_field(value)
    ismissing(value) && return ""
    text = string(value)
    return "\"" * replace(text, "\"" => "\"\"") * "\""
end

# ╔═╡ 065dba25-0a7a-4aeb-9197-d26db9c9a5a8
md"""
### Function: `append_result_csv` — Save one result immediately

Receives a CSV path and a named tuple. Writes column names for a new file, appends the row, flushes it, and closes the stream. Returns the absolute path. It is used for both individual runs and stage traces.
"""

# ╔═╡ e15dae4c-6fd7-4423-9b4c-307a0f9fe300
function append_result_csv(path, row)
    mkpath(dirname(abspath(path)))
    stream = open(path, isfile(path) ? "a" : "w")
    try
        position(stream) == 0 && println(stream, join(string.(keys(row)), ","))
        println(stream, join(csv_field.(values(row)), ","))
        flush(stream)
    finally
        close(stream)
    end
    return abspath(path)
end

# ╔═╡ 79524299-953d-4ea5-99ea-c5f555c2c73f
function solve_time0_serial(data; solver=:scip, instance="instance", run=1, time_limit=1800.0,
        seed=1, threads=1, max_binary_variables=2_000_000,
        log_file="", solution_file="", console=false, lock_tolerance=1e-7)
    isfinite(lock_tolerance) && lock_tolerance >= 0 || error("Invalid lock tolerance")
    formulation = build_time0_model(data; solver, time_limit, seed, threads,
        max_binary_variables, log_file="", console)
    model = formulation.model
    total_arcs = length(data.arcs)
    total_arcs > 0 || error("A network must contain at least one arc")
    stages = NamedTuple[]
    stage_rows = NamedTuple[]
    validation = nothing
    first_stage_bound = missing
    active_stage_bound = missing
    completed_stages = 0
    elapsed_optimize = 0.0
    total_nodes = 0
    nodes_available = true
    termination = "NOT_RUN"
    last_primal_status = "NO_SOLUTION"
    stage_csv = isempty(log_file) ? "" : replace(log_file,r"\.log$" => "") * "_stages.csv"
    !isempty(stage_csv) && isfile(stage_csv) && rm(stage_csv)
    for k in 1:total_arcs
        remaining = Float64(time_limit) - elapsed_optimize
        remaining <= 0 && break
        stage = add_lexicographic_stage!(formulation,k,total_arcs)
        push!(stages,stage)
        isnothing(validation) || warm_start_lexicographic!(data,formulation,validation,stages)
        solver_time_limit = set_stage_time_limit!(model,solver,remaining)
        stage_log = isempty(log_file) ? "" : replace(log_file,r"\.log$" => "") *
            "_stage-" * lpad(k,3,'0') * ".log"
        set_stage_log!(model,solver,stage_log; console)
        # Only optimize! is measured; every stage shares the same solve-time budget.
        seconds = try
            @elapsed optimize!(model)
        finally
            close_stage_log!(model,solver)
        end
        elapsed_optimize += seconds
        term = termination_status(model)
        termination = string(term)
        last_primal_status = string(primal_status(model))
        bound = try
            candidate_bound = objective_bound(model)
            isfinite(candidate_bound) ? candidate_bound : missing
        catch
            missing
        end
        active_stage_bound = bound
        k == 1 && (first_stage_bound = bound)
        nodes = try
            node_count(model)
        catch
            missing
        end
        if ismissing(nodes)
            nodes_available = false
        else
            total_nodes += nodes
        end
        has_incumbent = primal_status(model) == ORANGE_MOI.FEASIBLE_POINT
        solver_incumbent = has_incumbent ? objective_value(model) : missing
        if has_incumbent
            validation = validate_time0_solution(data,formulation)
        end
        # A previously validated route remains a feasible incumbent for the new stage.
        route_incumbent = isnothing(validation) ? missing :
            sum(sort(validation.arc_loads; rev=true)[1:k])
        row = (solver=String(solver),solver_version=orange_solver_version(solver),
            stage=k, objective="sum_of_largest_$(k)_loads", time_limit=remaining, solver_time_limit=solver_time_limit,
            optimize_seconds=seconds, cumulative_optimize_seconds=elapsed_optimize,
            solver_incumbent=solver_incumbent, route_incumbent=route_incumbent,
            lower_bound=bound, gap=experiment_gap(route_incumbent,bound),
            termination=string(term), primal_status=last_primal_status,
            nodes=nodes, log_file=isempty(stage_log) ? "" : abspath(stage_log))
        push!(stage_rows,row)
        isempty(stage_csv) || append_result_csv(stage_csv,row)
        if term == ORANGE_MOI.OPTIMAL && has_incumbent
            completed_stages = k
            if k < total_arcs
                # Numerical lexicographic lock; this is not a weighted-sum objective.
                @constraint(model, stage.expression <= solver_incumbent + lock_tolerance)
            end
        else
            break
        end
    end
    if elapsed_optimize >= time_limit && completed_stages < total_arcs
        termination = "TIME_LIMIT"
    end
    feasible = !isnothing(validation)
    sorted_loads = feasible ? sort(validation.arc_loads; rev=true) : Float64[]
    objective = feasible ? first(sorted_loads) : missing
    active_stage = isempty(stage_rows) ? 0 : last(stage_rows).stage
    active_objective = feasible && active_stage > 0 ? sum(sorted_loads[1:active_stage]) : missing
    status = completed_stages == total_arcs ? "Optimal" :
        (termination == "INFEASIBLE" && !feasible ? "Infeasible" : "Not Optimal")
    gap = experiment_gap(objective,first_stage_bound)
    if feasible && !isempty(solution_file)
        mkpath(dirname(abspath(solution_file)))
        solution = (instance=instance,run=run,solver=String(solver),
            solver_version=orange_solver_version(solver),objective_mode="lexicographic_sorted_loads",
            splitting=String(data.splitting),sorted_loads=sorted_loads,mlu=objective,
            lex_completed_stages=completed_stages,lex_total_stages=total_arcs,
            lock_tolerance=lock_tolerance,srpaths=validation.routes,
            arc_ids=data.arc_ids,arc_loads=validation.arc_loads)
        write(solution_file,JSON3.write(solution))
    end
    return (
        instance=String(instance), run=run, time=0,
        solver=String(solver),solver_version=orange_solver_version(solver),
        vertices=nv(data.graph), links=total_arcs, demands=length(data.v),
        objective=objective, lower_bound=first_stage_bound, cpu_time_seconds=elapsed_optimize,
        status=status, termination=termination, primal_status=last_primal_status,
        gap=gap, nodes=nodes_available ? total_nodes : missing,
        feasible=feasible, validated=feasible,
        checked_mlu=objective, lex_completed_stages=completed_stages,
        lex_total_stages=total_arcs, active_stage=active_stage,
        stage_objective=active_objective, stage_lower_bound=active_stage_bound,
        stage_gap=experiment_gap(active_objective,active_stage_bound),
        sorted_loads_json=JSON3.write(sorted_loads),
        time_limit=Float64(time_limit), seed=seed, threads=threads,
        objective_mode="lexicographic_sorted_loads", splitting=String(data.splitting),
        lock_tolerance=lock_tolerance, binary_variables=formulation.binary_variables,
        log_file=isempty(stage_csv) ? "" : abspath(stage_csv),
        solution_file=feasible && !isempty(solution_file) ? abspath(solution_file) : "", error="",
    )
end

# ╔═╡ b45ba371-ec46-460d-8ab7-982ce5e4d2a7
md"""
### Function: `result_mean` — Average available observations

Receives result rows and a field name. Returns the arithmetic mean of available values, or missing if none exists. Missing objectives, gaps, or node counts never contribute a zero to an average.
"""

# ╔═╡ 8ddca20c-9671-45d8-b147-8cb1d55e1b25
function result_mean(rows, field)
    values_present = Float64[getproperty(row,field) for row in rows
        if !ismissing(getproperty(row,field)) && !isnothing(getproperty(row,field))]
    return isempty(values_present) ? missing : sum(values_present) / length(values_present)
end

# ╔═╡ eaa7dc15-b400-42a2-8260-d1a19ebdf54f
md"""
### Function: `summarize_experiments` — Build the report table

Receives all completed/checkpointed rows and a summary path. Groups runs by solver and instance, computes averages, and reports executed, feasible, optimal, infeasible, and failed run counts along with sample counts. Returns summary rows and writes summary.csv. The objective and gap columns refer specifically to MLU; full lexicographic progress is reported separately.
"""

# ╔═╡ eedc2106-b9c7-46fc-9baf-75eec4ca5b5e
function summarize_experiments(rows, summary_file)
    isfile(summary_file) && rm(summary_file)
    summary = NamedTuple[]
    for (solver,instance) in sort(unique([(row.solver,row.instance) for row in rows]))
        group = [row for row in rows if row.instance == instance && row.solver == solver]
        first_row = first(group)
        feasible_group = [row for row in group if row.feasible]
        executed = [row for row in group if row.termination != "ERROR" && row.termination != "MODEL_SIZE_LIMIT"]
        row = (
            solver=solver,solver_version=first_row.solver_version,
            instance=instance, vertices=first_row.vertices, links=first_row.links,
            demands=first_row.demands, requested_runs=length(group), executed_runs=length(executed),
            feasible_runs=length(feasible_group), optimal_runs=count(r -> r.status == "Optimal",group),
            infeasible_runs=count(r -> r.status == "Infeasible",group),
            error_runs=length(group)-length(executed),
            objective_mean=result_mean(feasible_group,:objective),
            cpu_time_mean=result_mean(executed,:cpu_time_seconds),
            gap_mean=result_mean(feasible_group,:gap), nodes_mean=result_mean(executed,:nodes),
            lex_completed_stages_mean=result_mean(executed,:lex_completed_stages),
            lex_total_stages=first_row.lex_total_stages,
            objective_samples=count(r -> !ismissing(r.objective) && !isnothing(r.objective),group),
            gap_samples=count(r -> !ismissing(r.gap) && !isnothing(r.gap),group),
            node_samples=count(r -> !ismissing(r.nodes) && !isnothing(r.nodes),group),
        )
        push!(summary,row)
        append_result_csv(summary_file,row)
    end
    return summary
end

# ╔═╡ b46c8f86-0c41-465a-93cf-ad5eaf2df9cc
md"""
### Function: `experiment_error_row` — Record an unexecuted or failed solve honestly

Receives instance dimensions, settings, and an error message. Returns a result row with missing objective, gap, and solve time. MODEL_SIZE_LIMIT denotes a model rejected before optimization. ERROR denotes another failure. Both appear as Not Optimal and are excluded from executed-run averages; neither is a proof of infeasibility.
"""

# ╔═╡ 557949d4-6725-42ac-a286-14bb31703e54
function experiment_error_row(data, instance, run, time_limit, seed, threads, log_file, error_message, lock_tolerance, solver)
    size_limited = occursin("MODEL_SIZE_LIMIT:",error_message)
    return (
        instance=String(instance), run=run, time=0,
        solver=String(solver),solver_version=orange_solver_version(solver),
        vertices=nv(data.graph), links=length(data.arcs), demands=length(data.v),
        objective=missing, lower_bound=missing, cpu_time_seconds=missing,
        status="Not Optimal", termination=size_limited ? "MODEL_SIZE_LIMIT" : "ERROR",
        primal_status="NO_SOLUTION", gap=missing, nodes=missing, feasible=false, validated=false,
        checked_mlu=missing, lex_completed_stages=0, lex_total_stages=length(data.arcs),
        active_stage=0, stage_objective=missing, stage_lower_bound=missing, stage_gap=missing,
        sorted_loads_json="[]", time_limit=Float64(time_limit), seed=seed, threads=threads,
        objective_mode="lexicographic_sorted_loads", splitting=String(data.splitting),
        lock_tolerance=lock_tolerance, binary_variables=length(data.v)*length(data.segments), log_file=abspath(log_file),
        solution_file="", error=error_message,
    )
end

# ╔═╡ a6127bd7-6dee-4aba-a02a-c5d884b92e76
md"""
### Function: `run_seta_experiments` — Run and checkpoint the SetA experiment batch

Receives the solver (`:scip` by default), instance IDs, repeat count, time budget, output directory, seeds, threads, routing convention, and size limit. Loads Data once per instance and solves each requested repetition. Saves every run immediately, rebuilds summary tables, and records software/hardware information. Reusing the same directory with identical settings resumes checkpointed runs; different settings require a new directory. Interruptions propagate so Ctrl+C stops the batch without deleting completed runs.
"""

# ╔═╡ 470d4950-7398-46a8-998e-c8ca22eeca08
md"""
### Function: `warm_up_solver(solver; threads=1)`

Executes the four-stage tiny example using the selected backend before a batch.
Checks its known objective vector and status. These initialization and compilation
costs are excluded from measured SetA solves. Each comparison backend receives its
own warm-up; it does not depend on which backend was used in the visible demo.
"""

# ╔═╡ 71c8035c-d61c-411e-8414-2a24724ca8c7
md"""
## Small solver comparison

Both backends solve the same example with the same seed, single-thread setting,
and lexicographic tolerance. The vector must agree with `(1, 0.5, 0.5, 0)`.
The following displayed times are demonstration observations, not a SetA benchmark.
Use repeated SetA experiments for a performance comparison.
"""

# ╔═╡ 920564d7-f90e-4001-989c-3b134e4d9978
md"""
## Configure and run in Pluto

SCIP is the default backend. Keep `solver=:scip` in `experiment_settings`, or
select `solver=:highs` and a different output directory for comparison. Solver
name and native version are saved in every run, stage, solution, and summary.
The same mathematical model, lock tolerances, seeds, time budget, and routing
convention are used for both engines. Their search strategies can still differ.
The selected backend is warmed up on the small example before batch timing.

SCIP's `parallel/maxnthreads` and `lp/threads` settings are thread caps; ordinary
SCIP.jl uses `SCIPsolve` and does not automatically enable concurrent solving.
Use one thread for the initial controlled comparison.

The long batch is disabled by default. First try instance 1 with one repetition
and a 30-second budget in a separate output directory. After checking its CSV and
logs, use instances `1:20`, `runs=10`, and `time_limit=1800.0` for the assignment.
Set `run_full_experiments = true` in the next cell to execute the selected settings.
Do not edit model cells while a batch is running.

The direct MILP has `length(data.v) * length(data.segments)` binary variables.
SetA-20 alone has 957,600,000 of them. A configurable two-million-variable guard
rejects oversized models before allocation and records MODEL_SIZE_LIMIT. Such a
row is unexecuted, not an infeasibility result. Increasing the guard does not
remove the memory cost. The current mathematical model still requires a different
formulation or decomposition to solve the largest instances practically.

The routing convention remains `:uniform_paths`, matching the supplied
calculation handout. Choose `:ecmp` explicitly only if that convention is intended,
and use a separate results directory. This choice is recorded in every run.

"""

# ╔═╡ 93368143-57e3-49f6-b335-bd7ed2def16c
experiment_settings = (
    solver=:scip, instances=1:20, runs=10, time_limit=1800.0,
    output_dir=joinpath(@__DIR__,"results","time0_lex_scip"),
    seed_base=1000, threads=1, splitting=:uniform_paths,
    max_binary_variables=2_000_000, lock_tolerance=1e-7,
)

# ╔═╡ 049ca407-1a66-47e0-9c17-374454364ef3
run_full_experiments = false

# ╔═╡ 9857c7d8-057c-45fa-aa32-4a8306052ec7
md"""
## Run from Terminal and inspect the files

From the project directory, install the locked environment once:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Then a short trial is:

```sh
julia --project=. scripts/run_experiments.jl --instances 1 --runs 1 --time-limit 30 --solver scip --output results/trial_lex_scip
```

The assignment configuration is:

```sh
julia --project=. scripts/run_experiments.jl --instances 1:20 --runs 10 --time-limit 1800 --solver scip --output results/time0_lex_scip
```

To run the same configuration with HiGHS:

```sh
julia --project=. scripts/run_experiments.jl --solver highs --instances 1:20 --runs 10 --time-limit 1800 --output results/time0_lex_highs
```

Keep both output directories separate. The saved config rejects attempts to
resume results with a different solver or native version.

For a durable console transcript in zsh/bash, append
`2>&1 | tee results_console.log`. Per-stage solver logs are written even without tee.
Ctrl+C stops the batch; rerunning the same command resumes completed run checkpoints.
Use a different output directory when changing settings. Failed or size-limited
checkpoints are retained too; inspect them before deciding to repeat a run.

Each output directory contains:

- `config.json` and `environment.json`: settings, versions, hardware, timing definition.
- `runs.csv`: one row per repetition, with dimensions, objective vector, MLU/bounds/gaps,
  optimize! time, nodes, statuses, stage progress, seeds, and validation result.
- `summary.csv`: averages and explicit counts by instance.
- `setA-01_run-01.json`: completed-run checkpoint used for resume.
- `setA-01_run-01_stages.csv`: individual stage timings, objectives, bounds, gaps, and log paths.
- `setA-01_run-01_stage-001.log`, etc.: the selected solver's log for each attempted stage.
- `setA-01_run-01_solution.json`: waypoint lists, physical arc loads, and the full sorted vector.

Rows with MODEL_SIZE_LIMIT or ERROR have no solve time or objective and are counted
separately from executed runs. The largest-instance limitation is explicit in the
summary; those experiments still need a scalable solution method.

"""

# ╔═╡ 51d7e27f-cac3-4a78-953f-1f2152174673
md"""
### Function: `experiment_summary_table(summary)`

Receives the summary rows returned by the batch runner. Returns a Markdown table
for display in Pluto, with means, valid objective sample counts, optimal-run counts,
and lexicographic stage progress. Missing values are displayed as `NA`. It does
not solve a model or change the saved numerical results.
"""

# ╔═╡ 7a3fa790-8a45-4ef3-9634-22990d4b691c
function experiment_summary_table(summary)
    lines = [
        "| Solver | Instance | Vertices | Links | Demands | Mean MLU | Mean optimize! seconds | Mean MLU gap | Mean nodes | Optimal / requested | Mean stages / total | Objective samples |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summary
        metrics = [row.objective_mean,row.cpu_time_mean,row.gap_mean,row.nodes_mean]
        displayed = [ismissing(v) ? "NA" : string(round(v;digits=6)) for v in metrics]
        stages = ismissing(row.lex_completed_stages_mean) ? "NA" :
            string(round(row.lex_completed_stages_mean;digits=2))
        push!(lines,"| $(row.solver) | $(row.instance) | $(row.vertices) | $(row.links) | $(row.demands) | " *
            join(displayed," | ") * " | $(row.optimal_runs) / $(row.requested_runs) | " *
            stages * " / $(row.lex_total_stages) | $(row.objective_samples) |")
    end
    return Markdown.parse(join(lines,"\n"))
end

# ╔═╡ 7c4e16b6-a893-48da-98af-6e1fa7d2c271
md"""
### Function: `solve_time0(data; settings...)`

This public entry point defaults to `solver=:scip`; pass `solver=:highs` for
comparison. It serializes the notebook's solver calls with a lock and calls
`solve_time0_serial`. Only the HiGHS branch resets its global worker scheduler.
The lock is released even on error or Ctrl+C. Backend setup is outside the
optimize! timer. Do not run unrelated HiGHS instances concurrently in the same
Julia process. The mathematical constraints and lexicographic objectives are
identical for both backends.
"""

# ╔═╡ f1b17671-4b54-4b2b-9231-20300509c373
function solve_time0(data; solver=:scip, settings...)
    lock(ORANGE_SOLVER_LOCK)
    try
        solver in (:scip,:highs) || error("Unknown solver $solver; choose :scip or :highs")
        solver == :highs && HiGHS.Highs_resetGlobalScheduler(1)
        return solve_time0_serial(data; solver, settings...)
    finally
        unlock(ORANGE_SOLVER_LOCK)
    end
end

# ╔═╡ 1cbf9a85-1cb6-4d46-80cc-fecdd47e0ddf
lex_demo_result = solve_time0(lex_demo_data; instance="lex-demo", time_limit=5.0,
    log_file=joinpath(@__DIR__,"results","demo_scip","lex-demo.log"),
    solution_file=joinpath(@__DIR__,"results","demo_scip","lex-demo_solution.json"))

# ╔═╡ 183437f5-305b-4b4d-abea-3fe485de65d5
(
    solver = lex_demo_result.solver,
    solver_version = lex_demo_result.solver_version,
    expected_sorted_loads = [1.0,0.5,0.5,0.0],
    calculated_sorted_loads = JSON3.read(lex_demo_result.sorted_loads_json),
    status = lex_demo_result.status,
    completed_stages = lex_demo_result.lex_completed_stages,
    total_stages = lex_demo_result.lex_total_stages,
    optimize_seconds = lex_demo_result.cpu_time_seconds,
    stage_log_index = lex_demo_result.log_file,
)

# ╔═╡ d292ba9d-c6ac-48cf-a45d-1c18a8c2adb7
function warm_up_solver(solver::Symbol; threads=1)
    result = solve_time0(time0_demo_data(); solver, threads, time_limit=10.0)
    expected = [1.0,0.5,0.5,0.0]
    result.status == "Optimal" || error("Solver $solver did not finish warm-up")
    isapprox(collect(JSON3.read(result.sorted_loads_json)),expected;atol=1e-5) ||
        error("Solver $solver failed the known lexicographic warm-up example")
    return nothing
end

# ╔═╡ 52d0d4be-c70c-4967-965b-b7072c90a6c3
lex_demo_highs_result = solve_time0(lex_demo_data; solver=:highs,
    instance="lex-demo", time_limit=5.0,
    log_file=joinpath(@__DIR__,"results","demo_highs","lex-demo.log"),
    solution_file=joinpath(@__DIR__,"results","demo_highs","lex-demo_solution.json"))

# ╔═╡ def88c7f-a905-4f08-9cca-b7793b61c045
let
    lines = ["| Solver | Native version | Sorted loads | Status | Stages | optimize! seconds |",
        "|---|---|---|---|---:|---:|"]
    for row in (lex_demo_result,lex_demo_highs_result)
        push!(lines,"| $(row.solver) | $(row.solver_version) | $(row.sorted_loads_json) | " *
            "$(row.status) | $(row.lex_completed_stages)/$(row.lex_total_stages) | " *
            "$(round(row.cpu_time_seconds;digits=6)) |")
    end
    Markdown.parse(join(lines,"\n"))
end

# ╔═╡ d4e261ad-a0f6-4cd4-9c30-d351c3bdcf93
function run_seta_experiments(; solver=:scip, instances=1:20, runs=10, time_limit=1800.0,
        output_dir=nothing, seed_base=1000, threads=1,
        splitting=:uniform_paths, max_binary_variables=2_000_000, console=false, lock_tolerance=1e-7)
    solver in (:scip,:highs) || error("Unknown solver $solver; choose :scip or :highs")
    output_dir = isnothing(output_dir) ? joinpath(@__DIR__,"results","time0_lex_$(solver)") : abspath(output_dir)
    runs >= 1 || error("runs must be positive")
    isfinite(time_limit) && time_limit > 0 || error("Invalid time limit")
    ids = collect(Int, instances)
    !isempty(ids) && all(i -> 1 <= i <= 20, ids) && length(unique(ids)) == length(ids) || error("Invalid instance IDs")
    mkpath(output_dir)
    config = (schema_version=2, solver=String(solver),solver_version=orange_solver_version(solver),
        instances=ids, runs=runs, time_limit=Float64(time_limit), seed_base=seed_base,
        threads=threads, splitting=String(splitting), objective_mode="lexicographic_sorted_loads",
        max_binary_variables=max_binary_variables,lock_tolerance=lock_tolerance,
        relative_gap_tolerance=0.0,absolute_gap_tolerance=1e-8,feasibility_tolerance=1e-7)
    config_path = joinpath(output_dir,"config.json")
    config_text = JSON3.write(config)
    if isfile(config_path)
        read(config_path,String) == config_text || error("Existing output directory has different settings; choose a new directory")
    else
        write(config_path,config_text)
        environment = (solver=String(solver),solver_version=orange_solver_version(solver),
            julia=string(VERSION), jump=string(Base.pkgversion(JuMP)),
            scip_jl=string(Base.pkgversion(SCIP)), highs_jl=string(Base.pkgversion(HiGHS)), cpu=Sys.CPU_NAME, kernel=string(Sys.KERNEL),
            architecture=string(Sys.ARCH), threads=threads, julia_threads=Threads.nthreads(),
            warmup_excluded=true,created_utc=string(Dates.now(Dates.UTC)), cpu_time_definition="wall time of optimize! only")
        write(joinpath(output_dir,"environment.json"),JSON3.write(environment))
    end
    println("Warm-up: ",solver," (excluded from reported solve times)")
    warm_up_solver(solver;threads)
    result_file = joinpath(output_dir,"runs.csv")
    # JSON checkpoints are authoritative; rebuild CSV to avoid duplicate rows on resume.
    isfile(result_file) && rm(result_file)
    rows = NamedTuple[]
    for id in ids
        instance = "setA-" * lpad(id,2,'0')
        data = load_data(joinpath(@__DIR__,"setA",instance); splitting)
        for run in 1:runs
            basename_run = instance * "_run-" * lpad(run,2,'0')
            checkpoint = joinpath(output_dir,basename_run * ".json")
            log_file = joinpath(output_dir,basename_run * ".log")
            solution_file = joinpath(output_dir,basename_run * "_solution.json")
            seed = seed_base + run
            if isfile(checkpoint)
                saved = JSON3.read(read(checkpoint,String))
                row = (; (Symbol(key) => (isnothing(value) ? missing : value) for (key,value) in pairs(saved))...)
            else
                try
                    row = solve_time0(data; solver, instance, run, time_limit, seed, threads,
                        max_binary_variables, log_file, solution_file, console, lock_tolerance)
                catch exception
                    exception isa InterruptException && rethrow()
                    message = sprint(showerror,exception)
                    row = experiment_error_row(data,instance,run,time_limit,seed,threads,log_file,message,lock_tolerance,solver)
                    write(log_file,message * "\n")
                end
                temporary_checkpoint = checkpoint * ".tmp"
                write(temporary_checkpoint,JSON3.write(row))
                mv(temporary_checkpoint,checkpoint; force=true)
            end
            push!(rows,row)
            append_result_csv(result_file,row)
            println(solver," | ",instance," run ",run,"/",runs,": ",row.status,
                " | objective=",row.objective," | seconds=",row.cpu_time_seconds,
                " | termination=",row.termination)
            flush(stdout)
        end
        summarize_experiments(rows,joinpath(output_dir,"summary.csv"))
    end
    summary = summarize_experiments(rows,joinpath(output_dir,"summary.csv"))
    return (; rows, summary, output_dir=abspath(output_dir))
end

# ╔═╡ d0b98a0a-fbfe-4fe0-b4d4-a9e81971c11d
experiment_results = if run_full_experiments
    run_seta_experiments(; experiment_settings...)
else
    md"Batch disabled. Set run_full_experiments = true to execute the settings above."
end

# ╔═╡ f4415922-4ed1-4d62-b970-3d5cddff3a71
experiment_table = if run_full_experiments
    experiment_summary_table(experiment_results.summary)
else
    md"The summary table will appear here after the batch runs."
end

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Graphs = "86223c79-3864-5bf0-83f7-82e725a168b6"
HiGHS = "87dc4568-4c63-4d18-b0c0-bb2238e4078b"
JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
JuMP = "4076af6c-e467-56ae-b986-b466b2749572"
SCIP = "82193955-e24f-5292-bf16-6f2c5261a85f"
SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"

[compat]
Graphs = "~1.15.0"
HiGHS = "~1.26.0"
JSON3 = "~1.14.3"
JuMP = "~1.32.1"
SCIP = "~0.12.8"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.13.1"
manifest_format = "2.1"
project_hash = "aca9366d3f5142ac21c444ec28f70edcde92faac"

[[deps.ASL_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "21a22cd1a6d45034933824665cfb874ec425a14b"
registries = "General"
uuid = "ae81ac8f-d209-56e5-92de-9978fef736f9"
version = "0.1.5+0"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.2"

[[deps.ArnoldiMethod]]
deps = ["LinearAlgebra", "Random", "StaticArrays"]
git-tree-sha1 = "d57bd3762d308bded22c3b82d033bff85f6195c6"
registries = "General"
uuid = "ec485272-7323-5ecc-a04f-4719b315124d"
version = "0.4.0"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"
version = "1.11.0"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
version = "1.11.0"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1b96ea4a01afe0ea4090c5c8039690672dd13f2e"
registries = "General"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.9+0"

[[deps.CodecBzip2]]
deps = ["Bzip2_jll", "TranscodingStreams"]
git-tree-sha1 = "84990fa864b7f2b4901901ca12736e45ee79068c"
registries = "General"
uuid = "523fee87-0ab8-5b00-afb7-3ecf72e48cfd"
version = "0.8.5"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "970758a3d591a2a5c2a907c53f2e2f8c1b1d3537"
registries = "General"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.9"

[[deps.CommonSubexpressions]]
deps = ["MacroTools"]
git-tree-sha1 = "cda2cfaebb4be89c9084adaca7dd7333369715c5"
registries = "General"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.1"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.5.5+2"

[[deps.DataStructures]]
deps = ["OrderedCollections"]
git-tree-sha1 = "b0bc6d2cad1fed8b7fd59a1551a991cb3d2809e6"
registries = "General"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.19.6"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
version = "1.11.0"

[[deps.DiffResults]]
deps = ["StaticArraysCore"]
git-tree-sha1 = "782dd5f4561f5d267313f23853baaaa4c52ea621"
registries = "General"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.1.0"

[[deps.DiffRules]]
deps = ["IrrationalConstants", "LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "79a2aca180a85c690c58a020d47b426954b590f8"
registries = "General"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.16.0"

[[deps.DocStringExtensions]]
git-tree-sha1 = "8eeb56c16e74c6592afc69d2bb9e6082ba6aa850"
registries = "General"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.10.0"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.7.0"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"
version = "1.11.0"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions"]
git-tree-sha1 = "3b0f72e2ffef1a139ac450725c9ecd01c0a3c050"
registries = "General"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "1.4.6"
weakdeps = ["StaticArrays"]

    [deps.ForwardDiff.extensions]
    ForwardDiffStaticArraysExt = "StaticArrays"

[[deps.GMP_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "781609d7-10c4-51f6-84f2-b8444358ff6d"
version = "6.3.0+2"

[[deps.Graphs]]
deps = ["ArnoldiMethod", "DataStructures", "Inflate", "LinearAlgebra", "Random", "SimpleTraits", "SparseArrays", "Statistics"]
git-tree-sha1 = "dbb2b976f605b220dfe139d6db9f3859680da09e"
registries = "General"
uuid = "86223c79-3864-5bf0-83f7-82e725a168b6"
version = "1.15.0"

    [deps.Graphs.extensions]
    GraphsSharedArraysExt = "SharedArrays"

    [deps.Graphs.weakdeps]
    Distributed = "8ba89e20-285c-5b6f-9357-94700520ee1b"
    SharedArrays = "1a1011a3-84de-559e-8e89-a11a2f7dc383"

[[deps.HiGHS]]
deps = ["HiGHS_jll", "LinearAlgebra", "MathOptIIS", "MathOptInterface", "OpenBLAS32_jll", "PrecompileTools", "SparseArrays"]
git-tree-sha1 = "096cba93cdc8dd80451b7fa1cabfe3f34572f998"
registries = "General"
uuid = "87dc4568-4c63-4d18-b0c0-bb2238e4078b"
version = "1.26.0"

[[deps.HiGHS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Zlib_jll", "libblastrampoline_jll"]
git-tree-sha1 = "d4e63f395d10590fcece8d35005dd7b9a4862635"
registries = "General"
uuid = "8fd58aa0-07eb-5a78-9b36-339c94fd15ea"
version = "1.15.1+3"

[[deps.Hwloc_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "XML2_jll", "Xorg_libpciaccess_jll"]
git-tree-sha1 = "cbbd99d516990d05c02aa132aa077b2bf50ae323"
registries = "General"
uuid = "e33a78d0-f292-5ffc-b300-72abe9b543c8"
version = "2.15.0+0"

[[deps.Inflate]]
git-tree-sha1 = "d1b1b796e47d94588b3757fe84fbf65a5ec4a80d"
registries = "General"
uuid = "d25df0c9-e2be-5dd7-82c8-3ad0b3e990b9"
version = "0.1.5"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"
version = "1.11.0"

[[deps.Ipopt_jll]]
deps = ["ASL_jll", "Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "MUMPS_seq_jll", "SPRAL_jll", "libblastrampoline_jll"]
git-tree-sha1 = "0e144b24f0cfa8c5bfefcfdbdaae76132597394b"
registries = "General"
uuid = "9cc047cb-c261-5740-88fc-0cf96f7bdcc7"
version = "300.1400.2000+1"

[[deps.IrrationalConstants]]
git-tree-sha1 = "b2d91fe939cae05960e760110b328288867b5758"
registries = "General"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.2.6"

[[deps.JLLWrappers]]
deps = ["Artifacts", "Preferences"]
git-tree-sha1 = "7204148362dafe5fe6a273f855b8ccbe4df8173e"
registries = "General"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.8.0"

[[deps.JSON]]
deps = ["Dates", "Logging", "Parsers", "PrecompileTools", "StructUtils", "UUIDs", "Unicode"]
git-tree-sha1 = "9939eb6f799a963b3392ac4a1d49d3fc0646eb80"
registries = "General"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "1.11.0"

    [deps.JSON.extensions]
    JSONArrowExt = ["ArrowTypes"]

    [deps.JSON.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"

[[deps.JSON3]]
deps = ["Dates", "Mmap", "Parsers", "PrecompileTools", "StructTypes", "UUIDs"]
git-tree-sha1 = "411eccfe8aba0814ffa0fdf4860913ed09c34975"
registries = "General"
uuid = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
version = "1.14.3"

    [deps.JSON3.extensions]
    JSON3ArrowExt = ["ArrowTypes"]

    [deps.JSON3.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"

[[deps.JuMP]]
deps = ["LinearAlgebra", "MacroTools", "MathOptInterface", "MutableArithmetics", "OrderedCollections", "PrecompileTools", "Printf", "SparseArrays"]
git-tree-sha1 = "c21108220410d7b77d0385c487259abb7e5c97db"
registries = "General"
uuid = "4076af6c-e467-56ae-b986-b466b2749572"
version = "1.32.1"

    [deps.JuMP.extensions]
    JuMPDimensionalDataExt = "DimensionalData"

    [deps.JuMP.weakdeps]
    DimensionalData = "0703355e-b756-11e9-17c0-8b28908087d0"

[[deps.JuliaSyntaxHighlighting]]
deps = ["StyledStrings"]
uuid = "ac6e5ff7-fb65-4e79-a425-ec3bc9c03011"
version = "1.12.0"

[[deps.LazyArtifacts]]
deps = ["Artifacts", "Pkg"]
uuid = "4af54fe1-eca0-43a8-85a7-787d91b784e3"
version = "1.11.0"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "1.0.0"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "LibSSH2_jll", "Libdl", "OpenSSL_jll", "Zlib_jll", "Zstd_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.18.0+1"

[[deps.LibGit2]]
deps = ["LibGit2_jll", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"
version = "1.11.0"

[[deps.LibGit2_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "LibSSH2_jll", "Libdl", "OpenSSL_jll", "PCRE2_jll", "Zlib_jll"]
uuid = "e37daf67-58a4-590a-8e99-b0245dd2ffc5"
version = "1.9.1+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl", "OpenSSL_jll", "Zlib_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.104+0"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
version = "1.11.0"

[[deps.Libiconv_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "be484f5c92fad0bd8acfef35fe017900b0b73809"
registries = "General"
uuid = "94ce4f54-9a6c-5748-9c1c-f9c7231a4531"
version = "1.18.0+0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
version = "1.13.0"

[[deps.LogExpFunctions]]
deps = ["DocStringExtensions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "28d620bcdb37a3fb02de9f521928ee453690f414"
registries = "General"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "1.0.3"

    [deps.LogExpFunctions.extensions]
    LogExpFunctionsChainRulesCoreExt = "ChainRulesCore"
    LogExpFunctionsChangesOfVariablesExt = "ChangesOfVariables"
    LogExpFunctionsInverseFunctionsExt = "InverseFunctions"

    [deps.LogExpFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    ChangesOfVariables = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"
version = "1.11.0"

[[deps.METIS_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "5ecd92439c60a50c49bd6e96192e9d486b24b050"
registries = "General"
uuid = "d00139f3-1899-568f-a2f0-47f597d42d70"
version = "5.1.4+0"

[[deps.MPFR_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "GMP_jll", "Libdl"]
uuid = "3a97d323-0669-5f0c-9066-3539efd106a3"
version = "4.2.2+0"

[[deps.MUMPS_seq_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "METIS_jll", "libblastrampoline_jll"]
git-tree-sha1 = "fc1daa0ab5a0d7a0a34d5168a711cbf02b2cb0cc"
registries = "General"
uuid = "d7ed1dd3-d0ae-5e8e-bfb4-87a502085b8d"
version = "500.900.100+0"

[[deps.MacroTools]]
git-tree-sha1 = "1e0228a030642014fe5cfe68c2c0a818f9e3f522"
registries = "General"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.16"

[[deps.Markdown]]
deps = ["Base64", "JuliaSyntaxHighlighting", "StyledStrings"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"
version = "1.11.0"

[[deps.MathOptIIS]]
deps = ["MathOptInterface"]
git-tree-sha1 = "da7201fef4d3a70906723092d37a24a64ecab1bf"
registries = "General"
uuid = "8c4f8055-bd93-4160-a86b-a0c04941dbff"
version = "0.2.1"

[[deps.MathOptInterface]]
deps = ["CodecBzip2", "CodecZlib", "ForwardDiff", "JSON", "LinearAlgebra", "MutableArithmetics", "NaNMath", "OrderedCollections", "PrecompileTools", "Printf", "SparseArrays", "SpecialFunctions", "Test"]
git-tree-sha1 = "637aa0115265323850b125287833341a6f7b9b54"
registries = "General"
uuid = "b8f27783-ece8-5eb3-8dc8-9495eed66fee"
version = "1.54.0"

    [deps.MathOptInterface.extensions]
    MathOptInterfaceBenchmarkToolsExt = "BenchmarkTools"
    MathOptInterfaceCliqueTreesExt = "CliqueTrees"

    [deps.MathOptInterface.weakdeps]
    BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
    CliqueTrees = "60701a23-6482-424a-84db-faee86b9b1f8"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"
version = "1.11.0"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2026.8.13"

[[deps.MutableArithmetics]]
deps = ["LinearAlgebra", "SparseArrays", "Test"]
git-tree-sha1 = "158af80b4d50a7bdc37c8357c4c4554c335cfe5f"
registries = "General"
uuid = "d8a4904e-b15c-11e9-3269-09a3773c0cb0"
version = "1.9.0"

[[deps.NaNMath]]
deps = ["OpenLibm_jll"]
git-tree-sha1 = "dbd2e8cd2c1c27f0b584f6661b4309609c5a685e"
registries = "General"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "1.1.4"

[[deps.Ncurses_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "095850bc2a585bb20cad8d8f6f9f643d11b49a3d"
registries = "General"
uuid = "68e3532b-a499-55ff-9963-d1c0c0748b3a"
version = "6.6.0+2"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.3.0"

[[deps.OpenBLAS32_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "libblastrampoline_jll"]
git-tree-sha1 = "30870d0f2dc0b2dba76b10df1c58c7f018413e56"
registries = "General"
uuid = "656ef2d0-ae68-5445-9ca0-591084a874a2"
version = "0.3.34+0"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.30+0"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.7+0"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.5.6+0"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl"]
git-tree-sha1 = "1346c9208249809840c91b26703912dff463d335"
registries = "General"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.6+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "b079a6affebde167dad8ffe0d670b53917fbcb68"
registries = "General"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "2.0.3"

[[deps.PCRE2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "efcefdf7-47ab-520b-bdef-62a2eaa19f15"
version = "10.46.0+0"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "ba0dc8a8a67cacac4842631f960c046e4e563675"
registries = "General"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.8"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "FileWatching", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "Random", "SHA", "TOML", "Tar", "UUIDs", "Zstd_jll", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.13.0"

    [deps.Pkg.extensions]
    REPLExt = "REPL"

    [deps.Pkg.weakdeps]
    REPL = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "edbeefc7a4889f528644251bdb5fc9ab5348bc2c"
registries = "General"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.3.4"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "aef1987d90dcc2e2cbd919ad10b2d25bcce4f418"
registries = "General"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.6.1"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
version = "1.11.0"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
version = "1.11.0"

[[deps.Readline_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Ncurses_jll"]
git-tree-sha1 = "5d26d91800500cd67d4743cdbb59749e46ed726b"
registries = "General"
uuid = "05236dd9-4125-5232-aa7c-9ec0c9b2c25a"
version = "8.3.3+0"

[[deps.SCIP]]
deps = ["Libdl", "LinearAlgebra", "MathOptInterface", "OpenBLAS32_jll", "SCIP_PaPILO_jll", "SCIP_jll"]
git-tree-sha1 = "cfc4a317a683a8cd368bde015791055ddd09b9bd"
registries = "General"
uuid = "82193955-e24f-5292-bf16-6f2c5261a85f"
version = "0.12.8"

[[deps.SCIP_PaPILO_jll]]
deps = ["Artifacts", "Bzip2_jll", "CompilerSupportLibraries_jll", "GMP_jll", "Ipopt_jll", "JLLWrappers", "Libdl", "MPFR_jll", "OpenBLAS32_jll", "Readline_jll", "Zlib_jll", "bliss_jll", "boost_jll", "oneTBB_jll"]
git-tree-sha1 = "26d0bb9092bc1e0185598496414282e0d4d16869"
registries = "General"
uuid = "fc9abe76-a5e6-5fed-b0b7-a12f309cf031"
version = "1000.0.301+0"

[[deps.SCIP_jll]]
deps = ["Artifacts", "Bzip2_jll", "CompilerSupportLibraries_jll", "GMP_jll", "Ipopt_jll", "JLLWrappers", "Libdl", "MPFR_jll", "Readline_jll", "Zlib_jll", "boost_jll"]
git-tree-sha1 = "85beea85846e743c815b9d5470026429577d419e"
registries = "General"
uuid = "e5ac4fe4-a920-5659-9bf8-f9f73e9e79ce"
version = "1000.100.0+0"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "1.0.0"

[[deps.SPRAL_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Hwloc_jll", "JLLWrappers", "Libdl", "METIS_jll", "libblastrampoline_jll"]
git-tree-sha1 = "b78d602475715c9c6ea21c9650fa5dba58e9945b"
registries = "General"
uuid = "319450e9-13b8-58e8-aa9f-8fd1420848ab"
version = "2025.9.18+1"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"
version = "1.11.0"

[[deps.SimpleTraits]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "7ddb0b49c109481b046972c0e4ab02b2127d6a75"
registries = "General"
uuid = "699a6c99-e7fa-54fc-8d76-47d257e15c1d"
version = "0.9.6"

[[deps.SparseArrays]]
deps = ["Libdl", "LinearAlgebra", "Random", "Serialization", "SuiteSparse_jll"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
version = "1.13.0"

[[deps.SpecialFunctions]]
deps = ["IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "429071b23f4c9a13fb6582f807cc2ef454082408"
registries = "General"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.9.0"

    [deps.SpecialFunctions.extensions]
    SpecialFunctionsChainRulesCoreExt = "ChainRulesCore"

    [deps.SpecialFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "PrecompileTools", "Random", "StaticArraysCore"]
git-tree-sha1 = "de349d5585559b692f518b6d3fc7c179d64b2364"
registries = "General"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.9.23"

    [deps.StaticArrays.extensions]
    StaticArraysChainRulesCoreExt = "ChainRulesCore"
    StaticArraysStatisticsExt = "Statistics"

    [deps.StaticArrays.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    Statistics = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"

[[deps.StaticArraysCore]]
git-tree-sha1 = "6ab403037779dae8c514bad259f32a447262455a"
registries = "General"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.4"

[[deps.Statistics]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "e2b53ce13a53367e96601081e33d34746b571bad"
registries = "General"
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.11.5"
weakdeps = ["SparseArrays"]

    [deps.Statistics.extensions]
    SparseArraysExt = ["SparseArrays"]

[[deps.StructTypes]]
deps = ["Dates", "UUIDs"]
git-tree-sha1 = "fd6a55e88450cb4256e49103a5a243f065c7b781"
registries = "General"
uuid = "856f2bd8-1eba-4b0a-8007-ebc267875bd4"
version = "1.11.1"

[[deps.StructUtils]]
deps = ["Dates", "UUIDs"]
git-tree-sha1 = "ad435e30854ed0f50f4b7f67edd71664afecc5d8"
registries = "General"
uuid = "ec057cc2-7a8d-4b58-b3b3-92acb9f63b42"
version = "2.10.0"

    [deps.StructUtils.extensions]
    StructUtilsDataFramesExt = ["DataFrames"]
    StructUtilsLazilyInitializedFieldsExt = ["LazilyInitializedFields"]
    StructUtilsMeasurementsExt = ["Measurements"]
    StructUtilsStaticArraysCoreExt = ["StaticArraysCore"]
    StructUtilsTablesExt = ["Tables"]

    [deps.StructUtils.weakdeps]
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    LazilyInitializedFields = "0e77f7df-68c5-4e49-93ce-4cd80f5598bf"
    Measurements = "eff96d63-e80a-5855-80a2-b1b0885c5ab7"
    StaticArraysCore = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
    Tables = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"

[[deps.StyledStrings]]
uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
version = "1.11.0"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "7.10.1+0"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.0"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
version = "1.11.0"

[[deps.TranscodingStreams]]
git-tree-sha1 = "0c45878dcfdcfa8480052b6ab162cdd138781742"
registries = "General"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.11.3"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
version = "1.11.0"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
version = "1.11.0"

[[deps.XML2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libiconv_jll", "Zlib_jll"]
git-tree-sha1 = "b826aedca5fce2e3c91904e338c279e5c1a2da74"
registries = "General"
uuid = "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a"
version = "2.15.4+0"

[[deps.Xorg_libpciaccess_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "58972370b81423fc546c56a60ed1a009450177c3"
registries = "General"
uuid = "a65dc6b1-eb27-53a1-bb3e-dea574b5389e"
version = "0.19.0+0"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.3.1+2"

[[deps.Zstd_jll]]
deps = ["CompilerSupportLibraries_jll", "Libdl"]
uuid = "3161d3a3-bdf6-5164-811a-617609db77b4"
version = "1.5.7+1"

[[deps.bliss_jll]]
deps = ["Artifacts", "GMP_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "f8b75e896a326a162a4f6e998990521d8302c810"
registries = "General"
uuid = "508c9074-7a14-5c94-9582-3d4bc1871065"
version = "0.77.0+1"

[[deps.boost_jll]]
deps = ["Artifacts", "Bzip2_jll", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "25fb6ecbb784a45f8ea74584fa631a9e85393dd0"
registries = "General"
uuid = "28df3c45-c428-5900-9ff8-a3135698ca75"
version = "1.87.0+0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.15.0+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.67.1+0"

[[deps.oneTBB_jll]]
deps = ["Artifacts", "JLLWrappers", "LazyArtifacts", "Libdl"]
git-tree-sha1 = "da8c1f6eee04831f14edcfa5dae611d309807e57"
registries = "General"
uuid = "1317d2d5-d96f-522e-a858-c73665f53c3e"
version = "2022.3.0+0"

[[deps.p7zip_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.8.2+0"

[registries.General]
url = "https://github.com/JuliaRegistries/General.git"
uuid = "23338594-aafe-5451-b93e-139f81909106"
"""

# ╔═╡ Cell order:
# ╟─2cdaf3dd-0a25-4ce2-9da9-4ee017ca9a1b
# ╠═7fdb9545-2175-4cf3-862c-ccc4ebd1d627
# ╟─705b5e90-5ef4-4285-a46a-4ef4fb0dff01
# ╠═7e06044c-4f17-4753-8d29-54fea385e727
# ╟─dda5b3e7-2a6c-4df2-9fdc-e0784b4c3b94
# ╠═fee9dcd1-c6f5-46e7-9546-24ba4209efb2
# ╟─ae531c1a-a653-41bf-879c-799723f2a086
# ╟─43d0094d-56ff-4e00-9863-1e590a500fbd
# ╠═7ba74f02-ab39-4cce-a008-e456bccf8332
# ╟─f09af42c-d81b-4f31-8b7b-9f240c81be6b
# ╟─38301175-d029-4afc-b53e-0daa01a907c7
# ╠═41836f74-0f1f-4e99-a4fc-7be3c2f2cc55
# ╟─b5ec0ef2-7107-4b1c-8baa-ee686077eb0a
# ╠═aa5cf923-9654-4b58-8085-2b66ea3aca47
# ╟─63d45e27-6c5c-4755-9b94-4a7531c85599
# ╠═b58aa673-0039-483f-abd0-337c9b7e0a68
# ╠═72cbbb3d-6002-491b-9559-4d0955e077fb
# ╠═caa9cb28-0c1a-43be-97be-0b54fb06489c
# ╠═db1c3609-d65a-4e95-a215-815052cc27a1
# ╟─ee9d2d3e-6d88-4bf0-8038-1e0f9a2cdbee
# ╠═de136f32-2133-4e18-abef-fbb42cffd537
# ╟─2ca6ec67-4e36-4426-aa29-072d06b57cda
# ╠═a8bfaf8b-a886-48db-b27b-f68fbdfcc871
# ╠═0286942e-2224-4bad-b162-f3db59b674cb
# ╟─670cc8d4-0867-4838-a7a3-321eab3ce633
# ╟─ae4b5be8-dc73-4f32-9009-900a20ddf276
# ╟─07fc53b5-d72d-4135-ac04-ddd147c641df
# ╠═fc38f677-cab0-4d6a-8ee2-2cd5360d1107
# ╟─5d0089ff-b7cd-449a-8b90-dfb0bed95170
# ╠═c6571fd9-6161-4010-83b9-878be5565d4f
# ╟─60d722a6-4a74-478a-9a0c-0c8ee621c30a
# ╟─3fb349a8-71d0-4824-b6eb-d5ba20c6de4e
# ╠═23bcabc4-a9ea-4675-b4bd-45e1993e3863
# ╟─f70e64a7-360f-4c04-ace3-cbef7b206201
# ╠═eef04c78-4a67-4ec8-921d-d4b486f24cb2
# ╟─666bb559-ace9-46c3-9e73-a2cf9e8cf27b
# ╠═68972105-6d4c-4f91-815b-2e5749098ced
# ╟─fffc1e57-fe39-423e-9816-a157cc62bcc3
# ╠═292a9848-3359-4acc-998c-f9323ee75cde
# ╟─6122b1a4-46f5-4e0a-b4f3-cfa91dd7dbf8
# ╠═14fc12c7-d155-4fdd-92b8-c4727f993b3a
# ╟─76bae8ac-9d90-45cf-a106-b2b89f257141
# ╟─134cd3a7-b362-4faf-91c7-f7505987a468
# ╠═3ec9a21c-de5f-4d98-914f-1f8a52a0fe14
# ╟─639dd9b5-2c73-4976-a91d-0ca342e9a730
# ╠═aa9b5be4-6deb-478e-95dc-0e70af0f1c06
# ╠═d323ce08-754c-48a3-99d8-69ced264e569
# ╟─0a74323a-829b-4252-abf4-74e2eb4d378b
# ╠═0cdf5c45-8acc-4ed7-b8fd-fcc8c55a7064
# ╟─6619e810-da86-474f-ba23-eace1ea0e41c
# ╠═6c2929c9-48ef-4131-ab8d-d7556cfa2a5f
# ╠═d3e7277b-763b-49d8-8c0d-62447a67da7d
# ╠═9eb9dfc3-9864-4aff-a57e-9e55cf1a80e0
# ╟─4d947c2c-0b50-466d-9531-11ae949b7475
# ╠═c11a6811-2307-4114-959f-33e003248779
# ╠═2abd4a34-78d3-41b8-af9a-4eb8de6f436b
# ╟─42025609-6da1-4f30-b179-2834cfda5f84
# ╠═af77aedb-41fd-44ce-8903-7c6b9a30eeee
# ╟─8285c789-4544-4e0b-ab93-06d50117a7fe
# ╠═a8a1398c-12d5-4487-ae3c-11ffb035aae6
# ╟─57a38ca7-5918-4ddf-b7b3-cb9f162b7e06
# ╠═d89ccb2f-9276-4840-b7b2-c4dd42c2f791
# ╟─23b5c53d-1c91-4827-891c-5ffe3278746a
# ╠═90f96945-670a-46ea-b65a-0f8adcabee5f
# ╟─f72ae162-d95f-493b-9b6f-6df649fd1c7b
# ╠═80be73dd-dbbc-4e1f-abdd-990290d138e7
# ╠═7e724cb5-ebfd-46eb-96db-c3338fd9682c
# ╟─01d94b4b-9344-40bc-a6d5-9a606214527a
# ╟─1dbfe41e-f2c5-48e9-ba14-0d3dfbac8953
# ╟─7fa918df-698f-4109-a3f1-f3610ff0089d
# ╟─3a0b9ef2-b4da-4d67-9774-a7f6dd0be497
# ╠═6a30c8cc-722c-4d0e-8f52-708b285aa477
# ╟─ad946052-f7b2-4283-af1e-6c1a5e9adc76
# ╠═62e7cb29-8eb2-4f7e-80e2-e3a5e4c59685
# ╟─572e721a-0b40-483d-9cca-699697e967b8
# ╠═34cb53e6-9d18-4e01-bb93-87d4b00b6191
# ╟─1935636c-86ae-4568-b106-eb860a63b493
# ╠═a1c4e846-ca92-4d46-b073-8d8ccfa2fa05
# ╟─b562a1eb-49cd-480b-8a74-9d445145a150
# ╠═ca0d5bf6-340c-48b8-89ce-23ffef2eda46
# ╠═72e9296a-3367-402d-9c66-88bf4026d4fa
# ╟─919891f0-8ace-459b-a20b-af51bfc1a72b
# ╠═0371b231-be81-4b68-b3cc-a59153b78de6
# ╟─8feaf3ce-4168-4e1f-b74a-28c2629331ed
# ╠═c72df640-0622-495a-bb90-e25dabf05398
# ╟─0de9cc87-9690-4d83-9801-79895e5c17df
# ╠═882f34a4-64c8-4f50-81e3-216f3a682ae6
# ╟─509862d6-b196-4c68-9b78-095105ade572
# ╠═9441b09a-b55a-4693-bb71-5fd48be058a5
# ╟─732eb7a7-7aa7-4ca1-8302-05a9d4d6cbda
# ╠═79524299-953d-4ea5-99ea-c5f555c2c73f
# ╟─4ad642fe-2c86-4d74-979a-b48d657f2917
# ╟─78a0ae6d-a64b-4f25-abb2-40bd06ab6e26
# ╠═07d9e8b5-b949-4581-b3ca-a13eac2f28f4
# ╠═43a769d5-c2db-451a-a2b1-dc3852794675
# ╠═1cbf9a85-1cb6-4d46-80cc-fecdd47e0ddf
# ╠═183437f5-305b-4b4d-abea-3fe485de65d5
# ╟─ae31ff5d-31d1-4080-bd5e-a1ad45d11609
# ╟─c0816744-3cf8-4925-a207-e993582610b8
# ╠═a48c15c8-a4b1-4d69-982f-81ffbb19ac45
# ╟─065dba25-0a7a-4aeb-9197-d26db9c9a5a8
# ╠═e15dae4c-6fd7-4423-9b4c-307a0f9fe300
# ╟─b45ba371-ec46-460d-8ab7-982ce5e4d2a7
# ╠═8ddca20c-9671-45d8-b147-8cb1d55e1b25
# ╟─eaa7dc15-b400-42a2-8260-d1a19ebdf54f
# ╠═eedc2106-b9c7-46fc-9baf-75eec4ca5b5e
# ╟─b46c8f86-0c41-465a-93cf-ad5eaf2df9cc
# ╠═557949d4-6725-42ac-a286-14bb31703e54
# ╟─a6127bd7-6dee-4aba-a02a-c5d884b92e76
# ╟─470d4950-7398-46a8-998e-c8ca22eeca08
# ╠═d292ba9d-c6ac-48cf-a45d-1c18a8c2adb7
# ╟─71c8035c-d61c-411e-8414-2a24724ca8c7
# ╠═52d0d4be-c70c-4967-965b-b7072c90a6c3
# ╠═def88c7f-a905-4f08-9cca-b7793b61c045
# ╠═d4e261ad-a0f6-4cd4-9c30-d351c3bdcf93
# ╟─920564d7-f90e-4001-989c-3b134e4d9978
# ╠═93368143-57e3-49f6-b335-bd7ed2def16c
# ╠═049ca407-1a66-47e0-9c17-374454364ef3
# ╠═d0b98a0a-fbfe-4fe0-b4d4-a9e81971c11d
# ╟─9857c7d8-057c-45fa-aa32-4a8306052ec7
# ╟─51d7e27f-cac3-4a78-953f-1f2152174673
# ╠═7a3fa790-8a45-4ef3-9634-22990d4b691c
# ╠═f4415922-4ed1-4d62-b970-3d5cddff3a71
# ╟─7c4e16b6-a893-48da-98af-6e1fa7d2c271
# ╠═f1b17671-4b54-4b2b-9231-20300509c373
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
