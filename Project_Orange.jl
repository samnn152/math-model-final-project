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

With the optional handout convention `splitting=:uniform_paths`, each arc `(u,v)` is checked against
the shortest-distance equality. Eligible arcs receive
`counts[i,u] * counts[v,j] / counts[i,j]`; all others remain zero. Diagonal and
unreachable pairs are zero. The optional `:ecmp` branch instead propagates unit
flow towards each destination and splits it equally between shortest-path next
hops. The numbered Data calculation uses the default handout formula.
"""

# ╔═╡ 292a9848-3359-4acc-998c-f9323ee75cde
function ratios_from_shortest_data(g, weights, arcs, distances, counts; splitting=:ecmp)
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
function routing_ratios(g, weights, arcs; splitting=:ecmp)
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
`splitting` defaults to `:ecmp`, the original challenge convention. It reads the corresponding `-net.json`,
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
function load_data(prefix::AbstractString; splitting=:ecmp)
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

This displayed path-count formula is retained to explain the lecturer's handout and is selected only by `:uniform_paths`.

The active Data calculation uses the original subject's `:ecmp` convention. For target j, let N_j(u) contain the outgoing shortest-path arcs from u. Starting with one unit at i, process vertices in decreasing distance to j and distribute the incoming flow f_u equally:

```math
r(i,j,(u,v),0)=f_u/|N_j(u)|,\quad (u,v)\in N_j(u),
\qquad f_v\leftarrow f_v+r(i,j,(u,v),0).
```

ECMP and uniform complete-path splitting can differ. Every result records the selected convention; older uniform-path pilots must not be mixed with the ECMP results.

"""

# ╔═╡ c11a6811-2307-4114-959f-33e003248779
r = ratios_from_shortest_data(g, routing_weights, arcs, scaled_distances, sigma; splitting=:ecmp)

# ╔═╡ 2abd4a34-78d3-41b8-af9a-4eb8de6f436b
(
    dimensions = size(r),
    time_indices = axes(r, 4),
    nonzero_coefficients = nnz(r.values),
    convention = :ecmp,
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
    splitting=:ecmp, time=0,
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

Receives prepared Data, solver settings, and a model-size limit. Returns the JuMP model, segment-choice variables, load expressions, and waypoint positions. It adds the constraints written above and supplies direct routing as a feasible initial solution. Only reachable segments are created. The size check runs before allocating the binary variables. Segment incidence lists are built in one pass, and sparse routing rows use an integer lookup array. Automatic JuMP string names are disabled to avoid allocating a name for every variable and constraint; Julia references such as `x[d,s]` remain available. These changes preserve variable order, coefficients, constraints, warm starts, solver settings, and lexicographic stages. They do not reduce the number of mathematical variables.
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

# ╔═╡ 883a391a-2e6e-4b9f-b03c-3416b8e13482
md"""
### HiGHS search profiles and deadline monitoring

`highs_search_options(profile)` returns native parameter changes only. `:default` keeps HiGHS defaults; `:devex` changes dual-simplex edge weights; `:incumbent` increases primal heuristic effort; `:lean` reduces cut-pool retention and turns off symmetry detection and non-root separation. None removes an original model constraint or changes the objective. Profiles require empirical comparison; a smaller cut pool is a soft target, not a RAM cap.

`HighsDeadlineMonitor` is a read-only native callback. It requests interruption at the remaining optimize! wall-time budget. Callback polling is cooperative and cannot guarantee an external hard deadline. Relative MIP gap remains zero: a requested approximate-quality threshold is reported separately and never used to lock an uncertified lexicographic stage.
"""

# ╔═╡ 1c1bff3e-050a-40b7-8799-9fe482e0dc5a
function highs_search_options(profile::Symbol)
    profile == :default && return Dict{String,Any}()
    profile == :devex && return Dict{String,Any}("simplex_dual_edge_weight_strategy"=>1)
    profile == :incumbent && return Dict{String,Any}(
        "mip_heuristic_effort"=>0.2, "mip_heuristic_run_shifting"=>true)
    profile == :lean && return Dict{String,Any}(
        "mip_pool_soft_limit"=>1000, "mip_pool_age_limit"=>10,
        "mip_detect_symmetry"=>false, "mip_allow_cut_separation_at_nodes"=>false)
    error("Unknown HiGHS profile $profile")
end

# ╔═╡ 19285b33-616b-409e-8481-1306f86498a8
begin
mutable struct HighsDeadlineMonitor <: Function
    deadline_ns::UInt64
    calls::Int
    interrupt_requested::Bool
end

function (monitor::HighsDeadlineMonitor)(callback_type::Cint, message::Ptr{Cchar},
        data::HiGHS.HighsCallbackDataOut)::Cint
    monitor.calls += 1
    if time_ns() >= monitor.deadline_ns
        monitor.interrupt_requested = true
        return Cint(1)
    end
    return Cint(0)
end
end

# ╔═╡ fa63c98d-74b0-477c-ab15-261bb423b147
function install_highs_deadline!(model, remaining; enabled=true)
    enabled || return nothing
    monitor = HighsDeadlineMonitor(time_ns() + UInt64(round(remaining * 1e9)), 0, false)
    callback_types = Cint[HiGHS.kHighsCallbackSimplexInterrupt,
        HiGHS.kHighsCallbackIpmInterrupt, HiGHS.kHighsCallbackMipInterrupt]
    ORANGE_MOI.set(model, HiGHS.CallbackFunction(callback_types), monitor)
    return monitor
end

# ╔═╡ 3c6a6416-d8c3-4169-b572-a8ffbd82eed5
function approximation_quality(feasible, mlu_gap, stage_gap, completed, total, target)
    0 <= target < 1 || error("Target gap must be in [0,1)")
    mlu_met = feasible && !ismissing(mlu_gap) && mlu_gap <= target
    stage_met = feasible && !ismissing(stage_gap) && stage_gap <= target
    label = !feasible ? "NO_FEASIBLE_SOLUTION" : completed == total ? "LEX_OPTIMAL" :
        mlu_met ? "MLU_TARGET_MET_LEX_INCOMPLETE" : "TARGET_NOT_MET"
    return (; target_gap=Float64(target), mlu_target_met=mlu_met,
        active_stage_target_met=stage_met, quality_status=label)
end

# ╔═╡ ad946052-f7b2-4283-af1e-6c1a5e9adc76
md"""
### Function: `create_time0_optimizer`

Creates the selected direct JuMP backend. HiGHS is the public solve default; SCIP remains selectable. Applies the requested seed, thread limits, zero relative objective gap, absolute gap 1e-8 and feasibility tolerance 1e-7 with solver-specific parameter names. SCIP uses randomization/randomseedshift, limits/gap and limits/absgap; HiGHS uses random_seed, mip_rel_gap and mip_abs_gap. The model equations are unchanged. Ordinary SCIP.jl optimize! uses SCIPsolve, not concurrent SCIPsolveConcurrent: thread options are caps on available SCIP/LP threading, not a promise of parallel branch-and-bound. Default single-thread runs make the initial comparison reproducible.
"""

# ╔═╡ 62e7cb29-8eb2-4f7e-80e2-e3a5e4c59685
function create_time0_optimizer(solver::Symbol; time_limit, seed, threads, console=false, highs_profile=:default)
    solver in (:scip,:highs) || error("Unknown solver $solver; choose :scip or :highs")
    highs_search_options(highs_profile)
    solver == :scip && highs_profile != :default && error("HiGHS profiles apply only to HiGHS")
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
        for (name,value) in highs_search_options(highs_profile)
            set_optimizer_attribute(model,name,value)
        end
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
function build_time0_model(data; solver=:highs, time_limit=1800.0, seed=1, threads=1,
        max_binary_variables=2_000_000, log_file="", console=false, highs_profile=:default)
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
    model = create_time0_optimizer(solver; time_limit, seed, threads, console, highs_profile)
    isempty(log_file) || set_stage_log!(model,solver,log_file; console)
    set_string_names_on_creation(model, false)
    @variable(model, x[1:k, 1:p], Bin)
    @variable(model, z >= 0)
    @variable(model, 0 <= position[1:k, 1:n] <= data.MaxSeg)
    outgoing = [Int[] for u in 1:n]
    incoming = [Int[] for u in 1:n]
    for (s,(i,j)) in enumerate(segments)
        push!(outgoing[i], s)
        push!(incoming[j], s)
    end
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
    segment_row = zeros(Int, n*n)
    for (s,(i,j)) in enumerate(segments)
        segment_row[i + (j-1)*n] = s
    end
    loads = [AffExpr(0.0) for a in 1:m]
    ratio_rows = rowvals(data.r.values)
    ratio_values = nonzeros(data.r.values)
    for a in 1:m
        for entry in nzrange(data.r.values, a)
            s = segment_row[ratio_rows[entry]]
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
function validate_time0_solution(data, formulation; tolerance=1e-5, candidate_x=nothing, candidate_z=nothing)
    model, x, segments = formulation.model, formulation.x, formulation.segments
    isnothing(candidate_x) && primal_status(model) != ORANGE_MOI.FEASIBLE_POINT && error("No feasible incumbent to validate")
    n, m, k = nv(data.graph), length(data.arcs), length(data.v)
    arc_loads = zeros(m)
    routes = NamedTuple[]
    selected_segments = Vector{Int}[]
    for d in 1:k
        selected = Int[]
        for s in eachindex(segments)
            value_x = isnothing(candidate_x) ? value(x[d,s]) : candidate_x[d,s]
            isfinite(value_x) && -tolerance <= value_x <= 1+tolerance || error("Invalid binary route value")
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
    z_value = isnothing(candidate_z) ? value(formulation.z) : candidate_z
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

An optional `stage_observer(model, solver, stage, log_path)` may read native statistics after each solve. It runs outside the optimize! timer and must not modify the model. The benchmark uses it only for diagnostics.
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
        demand_ids=[0,1],MaxSeg=2,r=routing.r,counts=routing.counts,segments=segments,time=0,splitting=:ecmp)
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

# ╔═╡ 0f630d76-c12e-4d83-a7a8-95a2eace1262
md"""
### Atomic checkpoints and solve events

`write_solution_checkpoint` persists an already validated feasible routing and its global bounds. `write_solve_event` marks the beginning/end of an optimize! call for an external process supervisor. These writes are outside measured solve time. A supervisor may kill an overdue process, but a saved incumbent remains a partial result, never an optimality certificate.
"""

# ╔═╡ ff5ffe39-dfc4-4ccf-9c44-f9d16548f205
function write_solve_event(log_file, event, remaining, stage)
    isempty(log_file) && return nothing
    path = log_file * ".event.json"
    mkpath(dirname(abspath(path)))
    temporary = path * ".tmp"
    write(temporary,JSON3.write((event=event,remaining_seconds=remaining,stage=stage,token=string(time_ns()))))
    mv(temporary,path;force=true)
    return nothing
end

# ╔═╡ 18d27926-6238-4933-a5f1-63b02bc39d1b
function write_solution_checkpoint(path,data,validation;solver,instance,run,completed,
        active_stage,lower_bound,stage_lower_bound,lock_tolerance,formulation,target_gap,
        proof_tolerance=0.0,termination="RUNNING",status="Not Optimal")
    isempty(path) && return nothing
    sorted_loads=sort(validation.arc_loads;rev=true)
    active_value=sum(sorted_loads[1:active_stage])
    gap=experiment_gap(validation.maximum_load,lower_bound)
    stage_gap=experiment_gap(active_value,stage_lower_bound)
    quality=approximation_quality(true,gap,stage_gap,completed,length(data.arcs),target_gap)
    row=(instance=instance,run=run,solver=String(solver),formulation=formulation,
        objective_mode="lexicographic_sorted_loads",splitting=String(data.splitting),
        validated=true,termination=termination,status=status,bound_scope="global",
        solver_version=orange_solver_version(solver),
        mlu=validation.maximum_load,lower_bound=lower_bound,gap=gap,
        active_stage=active_stage,stage_objective=active_value,stage_lower_bound=stage_lower_bound,stage_gap=stage_gap,
        lex_completed_stages=completed,lex_total_stages=length(data.arcs),
        target_gap=target_gap,quality_status=quality.quality_status,mlu_target_met=quality.mlu_target_met,
        active_stage_target_met=quality.active_stage_target_met,
        lock_tolerance=lock_tolerance,proof_tolerance=proof_tolerance,sorted_loads=sorted_loads,
        srpaths=validation.routes,arc_ids=data.arc_ids,arc_loads=validation.arc_loads)
    mkpath(dirname(abspath(path)))
    temporary=path*".tmp"
    write(temporary,JSON3.write(row))
    mv(temporary,path;force=true)
    return nothing
end

# ╔═╡ 79524299-953d-4ea5-99ea-c5f555c2c73f
function solve_time0_serial(data; solver=:highs, instance="instance", run=1, time_limit=1800.0,
        seed=1, threads=1, max_binary_variables=2_000_000,
        log_file="", solution_file="", console=false, lock_tolerance=1e-7, stage_observer=nothing,
        highs_profile=:default, target_gap=0.10, deadline_callback=true)
    isfinite(lock_tolerance) && lock_tolerance >= 0 || error("Invalid lock tolerance")
    0 <= target_gap < 1 || error("Target gap must be in [0,1)")
    formulation = build_time0_model(data; solver, time_limit, seed, threads,
        max_binary_variables, log_file="", console, highs_profile)
    model = formulation.model
    total_arcs = length(data.arcs)
    total_arcs > 0 || error("A network must contain at least one arc")
    stages = NamedTuple[]
    stage_rows = NamedTuple[]
    validation = validate_time0_solution(data,formulation;candidate_x=start_value.(formulation.x),candidate_z=start_value(formulation.z))
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
        write_solution_checkpoint(solution_file,data,validation;solver,instance,run,
            completed=completed_stages,active_stage=k,lower_bound=first_stage_bound,
            stage_lower_bound=active_stage_bound,lock_tolerance,formulation="compact",target_gap)
        write_solve_event(log_file,"start",remaining,k)
        deadline_monitor = solver == :highs ?
            install_highs_deadline!(model, remaining; enabled=deadline_callback) : nothing
        # Only optimize! is measured; every stage shares the same solve-time budget.
        seconds = try
            @elapsed optimize!(model)
        finally
            close_stage_log!(model,solver)
        end
        write_solve_event(log_file,"end",max(0.0,time_limit-elapsed_optimize-seconds),k)
        elapsed_optimize += seconds
        isnothing(stage_observer) || stage_observer(model, solver, k, stage_log)
        term = termination_status(model)
        termination = string(term)
        last_primal_status = string(primal_status(model))
        bound = try
            candidate_bound = objective_bound(model)
            # SCIP uses finite +/-1e20 sentinels when no finite dual bound exists.
            finite_bound = isfinite(candidate_bound) && (solver != :scip ||
                SCIP.SCIPisInfinity(unsafe_backend(model), abs(candidate_bound)) == 0)
            finite_bound ? candidate_bound : missing
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
            deadline_interrupt_requested=!isnothing(deadline_monitor) && deadline_monitor.interrupt_requested,
            deadline_callback_calls=isnothing(deadline_monitor) ? 0 : deadline_monitor.calls,
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
    active_gap = experiment_gap(active_objective,active_stage_bound)
    quality = approximation_quality(feasible,gap,active_gap,completed_stages,total_arcs,target_gap)
    if feasible
        write_solution_checkpoint(solution_file,data,validation;solver,instance,run,
            completed=completed_stages,active_stage=max(1,active_stage),lower_bound=first_stage_bound,
            stage_lower_bound=active_stage_bound,lock_tolerance,formulation="compact",target_gap,
            termination,status)
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
        stage_gap=active_gap,
        highs_profile=String(highs_profile), target_gap=quality.target_gap,
        mlu_target_met=quality.mlu_target_met, active_stage_target_met=quality.active_stage_target_met,
        quality_status=quality.quality_status, deadline_callback=deadline_callback,
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
function experiment_error_row(data, instance, run, time_limit, seed, threads, log_file, error_message, lock_tolerance, solver;
        highs_profile=:default, target_gap=0.10, deadline_callback=true)
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
        highs_profile=String(highs_profile), target_gap=Float64(target_gap),
        mlu_target_met=false, active_stage_target_met=false, quality_status="NO_FEASIBLE_SOLUTION",
        deadline_callback=deadline_callback, sorted_loads_json="[]", time_limit=Float64(time_limit), seed=seed, threads=threads,
        objective_mode="lexicographic_sorted_loads", splitting=String(data.splitting),
        lock_tolerance=lock_tolerance, binary_variables=length(data.v)*length(data.segments), log_file=abspath(log_file),
        solution_file="", error=error_message,
    )
end

# ╔═╡ a6127bd7-6dee-4aba-a02a-c5d884b92e76
md"""
### Function: `run_seta_experiments` — Run and checkpoint the SetA experiment batch

Receives the solver (`:highs` by default), instance IDs, repeat count, time budget, output directory, seeds, threads, routing convention, and size limit. Loads Data once per instance and solves each requested repetition. Saves every run immediately, rebuilds summary tables, and records software/hardware information. Reusing the same directory with identical settings resumes checkpointed runs; different settings require a new directory. Interruptions propagate so Ctrl+C stops the batch without deleting completed runs.
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

HiGHS is the default backend. Keep `solver=:highs` in `experiment_settings`, or
select `solver=:scip` and a different output directory for comparison. Solver
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
remove the memory cost. The automatic route formulation avoids allocating those compact variables.

The default is now `:ecmp`, matching the original subject. The older handout convention remains available explicitly as `:uniform_paths`. Never mix their result directories.

`formulation=:auto` uses the original compact MILP for at most 100,000 potential segment binaries and route columns otherwise. The displayed original constraints remain the reference; route-column equivalence, pricing bounds and limitations are explained below. The size guard applies to the selected formulation, not automatically to the potential compact size.

The requested quality target is `target_gap=0.10` for MLU only. A result must have `mlu_target_met=true` to meet it. No approximate stage is locked as optimal.

"""

# ╔═╡ 93368143-57e3-49f6-b335-bd7ed2def16c
experiment_settings = (
    solver=:highs, instances=1:20, runs=10, time_limit=1800.0,
    output_dir=joinpath(@__DIR__,"results","time0_lex_highs_ecmp"),
    seed_base=1000, threads=1, splitting=:ecmp,
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
julia --project=. scripts/run_experiments.jl --instances 1 --runs 1 --time-limit 30 --solver highs --output results/trial_highs_ecmp
```

The assignment configuration is:

```sh
julia --project=. scripts/run_experiments.jl --instances 1:20 --runs 10 --time-limit 1800 --solver highs --output results/time0_lex_highs_ecmp
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

This public entry point defaults to `solver=:highs`; pass `solver=:scip` for
comparison. It serializes the notebook's solver calls with a lock and calls
`solve_time0_serial`. Only the HiGHS branch resets its global worker scheduler.
The lock is released even on error or Ctrl+C. Backend setup is outside the
optimize! timer. Do not run unrelated HiGHS instances concurrently in the same
Julia process. The mathematical constraints and lexicographic objectives are
identical for both backends.
"""

# ╔═╡ 469bf80a-c389-4ea0-8187-1a8fc6e8037a
md"""
# Memory-efficient time-0 formulation: route columns

The original segment equations above remain the reference. For demand d, let P_d contain every valid source-to-target segment path with at most K segments. A column p is a complete path, not a physical shortest path. Its physical flows still follow the same r[i,j,a,0] and ECMP convention.

```math
\sum_{p\in P_d}y_{dp}=1,\quad y_{dp}\in\{0,1\},\qquad
L_{adp}=\frac{\nu(d,0)}{c(a)}\sum_{(i,j)\in p}r(i,j,a,0),\quad
\lambda_a=\sum_d\sum_{p\in P_d}L_{adp}y_{dp}.
```

A chosen column already satisfies source/target flow conservation and MaxSeg. Conversely, every valid simple segment route is a column. In time 0, deleting a waypoint cycle removes nonnegative physical load and consumes fewer segments; with no inter-period budget, a lexicographic optimum therefore exists among simple routes. This argument is specific to time 0 and does not justify the same deletion under time-coupled budgets.

The master keeps the same sequential top-k load objectives and earlier locks. A small column pool alone is a restricted model: its integer bound is **not** a global bound for Orange.

### Pricing and a global lower bound

Let alpha_d be the dual multiplier of a demand selection equality, and beta_a=-dual(load_row_a) >= 0. The minimum reduced cost over all routes of d is

```math
\rho_d=\min_{p\in P_d}\left(\nu(d,0)\sum_{(i,j)\in p}\sum_a
\frac{\beta_a r(i,j,a,0)}{c(a)}-\alpha_d\right).
```

A nonnegative weighted segment cost permits dynamic programming with at most K segments. All targets are covered; only a completed pricing sweep supplies a bound. If D_R is the restricted LP dual value, lowering each alpha_d by max(0,-rho_d) makes its missing-column inequalities feasible, giving

```math
LB=D_R+\sum_d\min(0,\rho_d)\le z^*_{LP}\le z^*_{IP}.
```

A numerical safety buffer is subtracted. Duals are taken from the entire master, including all previous lexicographic locks. Restricting the stored columns does not invalidate this corrected bound. A node source/sink cut supplies an additional MLU lower bound.

Only equality of a validated incumbent and this **global** bound within the recorded absolute proof tolerance certifies a stage. Otherwise, the solver expands the route pool and retries the same unfinished stage while budget remains; it never promotes a restricted-master OPTIMAL status to global OPTIMAL. This is not full Branch-and-Price, and a remaining integrality gap may prevent certification.

### Continued search at an unfinished stage

A completed restricted MIP does not end the run merely because its global gap remains positive. The solver retains the incumbent and strongest global bound, expands the route pool with additional valid simple waypoint sequences, reruns LP pricing and solves the restricted MIP in slices of at most 60 seconds. The initial per-demand pool cap grows on retries; the global variable guard remains active. Cycles are logged separately. Only global certification advances k. A solve budget, an explicit wall safeguard or the route allocation guard can stop an incomplete run; reaching the 10% MLU reporting threshold cannot.

Enumeration can require exponentially many candidates and this is still not full branch-and-price. The model is unchanged. Pure route work is outside optimize! timing; a wall safeguard bounds the overall search routine by the solve budget plus max(30 seconds, 10% of that budget), checked between cycles. The external supervisor may stop sooner according to its own allowances.

### Feasible initialization and quality

A bounded greedy search considers two-segment waypoint alternatives, accepting improvements of the sorted physical-load vector. It supplies columns and a feasible warm start only; all valid routes remain eligible for pricing. Every final route is independently reconstructed and its loads recomputed from r.

The requested MLU target is gap <= 10%. It is a reported quality target, not a relaxed lexicographic lock. TARGET_NOT_MET means the request has not been achieved for that instance. Small compact models remain available for differential verification.
"""

# ╔═╡ c3ed0cf3-8514-47da-9930-6c719844eb6a
md"""
### `OrangeRouteColumn`

Stores one demand, its complete waypoint path and sparse normalized physical-load contributions.
"""

# ╔═╡ 426ef93a-1177-4113-85be-a2013131b5e4
struct OrangeRouteColumn
    demand::Int
    path::Vector{Int}
    coefficients::SparseVector{Float64,Int}
end

# ╔═╡ b9b4c5be-a1f0-4a58-b88f-b6ca02da8616
md"""
### `OrangeRoutePool`

Stores generated columns, per-demand lookup and transposed sparse routing ratios; does not allocate all compact segment variables.
"""

# ╔═╡ 0e5bf6a1-e6d9-4517-bce7-eab1bccefe90
mutable struct OrangeRoutePool
    columns::Vector{OrangeRouteColumn}
    by_demand::Vector{Vector{Int}}
    keys::Vector{Set{Tuple}}
    ratios_by_pair::SparseMatrixCSC{Float64,Int}
end

# ╔═╡ f72de83e-7527-456c-a302-cfa339323893
md"""
### `add_route_column!`

Checks route endpoints, reachability, simplicity and MaxSeg before adding a nonduplicate sparse column within the pool limit.
"""

# ╔═╡ 04cf4dfd-193b-4737-b8d8-d040611338e7
function add_route_column!(pool, data, d, path; max_routes=16)
    key = Tuple(path)
    key in pool.keys[d] && return 0
    length(pool.by_demand[d]) >= max_routes && return 0
    first(path) == data.sources[d] && last(path) == data.targets[d] || error("Wrong route endpoints")
    length(path)-1 <= data.MaxSeg || error("Too many route segments")
    length(unique(path)) == length(path) || error("Repeated waypoint")
    n = nv(data.graph)
    coefficients = Dict{Int,Float64}()
    values = nonzeros(pool.ratios_by_pair)
    rows = rowvals(pool.ratios_by_pair)
    for h in 1:length(path)-1
        i,j = path[h],path[h+1]
        data.counts[i,j] > 0 || error("Unreachable segment")
        pair = i+(j-1)*n
        for entry in nzrange(pool.ratios_by_pair,pair)
            a = rows[entry]
            coefficients[a] = get(coefficients,a,0.0) + data.v[d]*values[entry]/data.c[a]
        end
    end
    indices = sort(collect(keys(coefficients)))
    vector = sparsevec(indices,[coefficients[a] for a in indices],length(data.arcs))
    push!(pool.columns,OrangeRouteColumn(d,copy(path),vector))
    push!(pool.by_demand[d],length(pool.columns))
    push!(pool.keys[d],key)
    return length(pool.columns)
end

# ╔═╡ 2e4328cc-785e-44ed-b548-4f4b920e7f7b
md"""
### `initial_route_pool`

Initializes one direct source-to-target segment per demand.
"""

# ╔═╡ fe4bdc91-0eb6-40bc-8cba-7ebfaa7334a3
function initial_route_pool(data)
    k = length(data.v)
    pool = OrangeRoutePool(OrangeRouteColumn[],[Int[] for d in 1:k],
        [Set{Tuple}() for d in 1:k],sparse(transpose(data.r.values)))
    for d in 1:k
        add_route_column!(pool,data,d,[data.sources[d],data.targets[d]])
    end
    return pool
end

# ╔═╡ 478f3c47-d0a9-4075-935f-0d122c393cb5
md"""
### `minimum_segment_routes`

Prices every demand using nonnegative weighted segment costs and hop-bounded dynamic programming. Returns complete=false if interrupted before all targets finish.
"""

# ╔═╡ 49fcd1cc-3ad0-4588-bc31-5a12f9c31ca6
function minimum_segment_routes(data, weights; deadline=Inf)
    n = nv(data.graph)
    costs = reshape(data.r.values * (weights ./ data.c),n,n)
    for j in 1:n, i in 1:n
        (i == j || data.counts[i,j] == 0) && (costs[i,j]=Inf)
    end
    route_costs = fill(Inf,length(data.v))
    paths = [Int[] for d in eachindex(data.v)]
    for target in sort(unique(data.targets))
        time() > deadline && return (; complete=false,route_costs,paths)
        previous = fill(Inf,n)
        previous[target] = 0.0
        successors = zeros(Int,n,data.MaxSeg)
        for h in 1:data.MaxSeg
            time() > deadline && return (; complete=false,route_costs,paths)
            current = copy(previous)
            # Column-major traversal reuses each costs[:,j] and previous[j].
            for j in 1:n
                isfinite(previous[j]) || continue
                for i in 1:n
                    candidate = costs[i,j] + previous[j]
                    if candidate < current[i]
                        current[i] = candidate
                        successors[i,h] = j
                    end
                end
            end
            previous = current
        end
        for d in eachindex(data.v)
            data.targets[d] == target || continue
            route_costs[d] = previous[data.sources[d]]
            path = [data.sources[d]]
            current = data.sources[d]
            for h in data.MaxSeg:-1:1
                current == target && break
                next_vertex = successors[current,h]
                iszero(next_vertex) && continue
                current = next_vertex
                push!(path,current)
            end
            last(path) == target || error("Pricing reconstruction failed")
            length(unique(path)) == length(path) || error("Pricing produced a cycle")
            paths[d] = path
        end
    end
    return (; complete=true,route_costs,paths)
end

# ╔═╡ 48e92439-c8b4-4dc7-bc07-588959337922
md"""
### `build_route_master`

Builds an LP or restricted binary route master with convexity, physical loads, top-k objectives and certified prior locks.
"""

# ╔═╡ b54c1180-cf5e-405a-9b4d-7e6905b570de
function build_route_master(data, pool, k, locks; solver=:highs, integer=true,
        time_limit=1800.0, seed=1, threads=1, max_binary_variables=2_000_000,console=false,highs_profile=:default)
    length(pool.columns) <= max_binary_variables || error("MODEL_SIZE_LIMIT: route pool exceeds variable guard")
    model = create_time0_optimizer(integer ? solver : :highs;
        time_limit,seed,threads=integer ? threads : 1,console,
        highs_profile=integer ? highs_profile : :default)
    set_string_names_on_creation(model,false)
    variables = VariableRef[]
    for p in eachindex(pool.columns)
        y = @variable(model,lower_bound=0.0,base_name="route_$p")
        integer && set_binary(y)
        push!(variables,y)
    end
    @variable(model,loads[1:length(data.arcs)] >= 0)
    @variable(model,z >= 0)
    convexity = [@constraint(model,sum(variables[p] for p in pool.by_demand[d]) == 1)
        for d in eachindex(data.v)]
    expressions = [AffExpr(0.0) for a in eachindex(data.arcs)]
    for (p,column) in enumerate(pool.columns)
        indices,coefficients = findnz(column.coefficients)
        for h in eachindex(indices)
            add_to_expression!(expressions[indices[h]],coefficients[h],variables[p])
        end
    end
    load_rows = [@constraint(model,expressions[a] <= loads[a]) for a in eachindex(data.arcs)]
    for a in eachindex(data.arcs)
        @constraint(model,loads[a] <= z)
    end
    master = (;model,y=variables,loads,z,convexity,load_rows)
    stages = NamedTuple[]
    for h in 1:k
        stage = add_lexicographic_stage!(master,h,length(data.arcs))
        push!(stages,stage)
        h < k && @constraint(model,stage.expression <= locks[h])
    end
    return (;master...,stages)
end

# ╔═╡ 74d13c6e-0d13-4c34-868f-b9a485687a80
md"""
### `append_priced_variable!`

Adds one continuous route variable and its coefficients to the existing restricted LP.
"""

# ╔═╡ 31a7b7be-dc05-4f55-887c-82a71cb6abae
function append_priced_variable!(master,pool,p)
    column = pool.columns[p]
    y = @variable(master.model,lower_bound=0.0,base_name="route_$p")
    push!(master.y,y)
    set_normalized_coefficient(master.convexity[column.demand],y,1.0)
    indices,coefficients = findnz(column.coefficients)
    for h in eachindex(indices)
        set_normalized_coefficient(master.load_rows[indices[h]],y,coefficients[h])
    end
    return nothing
end

# ╔═╡ 68d3cd68-1300-4f1f-ae75-a6d82dab0e58
md"""
### `validate_route_selection`

Independently checks each selected route and recomputes every physical arc load directly from r.
"""

# ╔═╡ 7d35907e-afc6-4cac-bee4-d3885f4f2459
function validate_route_selection(data,pool,selection)
    length(selection) == length(data.v) || error("Missing demand route")
    loads = zeros(length(data.arcs))
    routes = NamedTuple[]
    for d in eachindex(data.v)
        p = selection[d]
        column = pool.columns[p]
        column.demand == d || error("Route assigned to wrong demand")
        path = column.path
        first(path) == data.sources[d] && last(path) == data.targets[d] || error("Invalid endpoints")
        length(unique(path)) == length(path) || error("Route has a repeated waypoint")
        length(path)-1 <= data.MaxSeg || error("Segment limit exceeded")
        # Recompute from r rather than trusting stored master coefficients.
        for h in 1:length(path)-1
            i,j = path[h],path[h+1]
            data.counts[i,j] > 0 || error("Unreachable segment")
            for a in eachindex(data.arcs)
                loads[a] += data.v[d]*data.r[i,j,a,0]/data.c[a]
            end
        end
        push!(routes,(d=data.demand_ids[d],t=0,w=data.node_ids[path[2:end-1]]))
    end
    return (valid=true,maximum_load=maximum(loads;init=0.0),arc_loads=loads,
        routes=routes,selection=copy(selection))
end

# ╔═╡ a5aab9a2-4359-40a7-85f4-22a4f4715d11
md"""
### `start_route_master!`

Sets a complete feasible incumbent for route choices, loads and top-k epigraph variables.
"""

# ╔═╡ 92a75acf-fcb1-4e18-99da-4c62568c8af8
function start_route_master!(master,validation)
    for y in master.y
        set_start_value(y,0.0)
    end
    for p in validation.selection
        set_start_value(master.y[p],1.0)
    end
    for a in eachindex(master.loads)
        set_start_value(master.loads[a],validation.arc_loads[a])
    end
    set_start_value(master.z,validation.maximum_load)
    sorted_loads = sort(validation.arc_loads;rev=true)
    for stage in master.stages
        isnothing(stage.threshold) && continue
        threshold = sorted_loads[stage.k]
        set_start_value(stage.threshold,threshold)
        for a in eachindex(master.loads)
            set_start_value(stage.excess[a],max(0.0,validation.arc_loads[a]-threshold))
        end
    end
    return nothing
end

# ╔═╡ ecb8cc09-f4f3-40c9-a104-fcb8760fadf1
md"""
### `sparse_route_loads`

Computes one route contribution from sparse routing columns without expanding demand-by-segment tensors.
"""

# ╔═╡ da4dedcf-d034-4ad3-8b32-eac230815a68
function sparse_route_loads(data,pool,d,path)
    loads = zeros(length(data.arcs))
    n = nv(data.graph)
    rows,values = rowvals(pool.ratios_by_pair),nonzeros(pool.ratios_by_pair)
    for h in 1:length(path)-1
        pair = path[h]+(path[h+1]-1)*n
        for entry in nzrange(pool.ratios_by_pair,pair)
            a=rows[entry]
            loads[a] += data.v[d]*values[entry]/data.c[a]
        end
    end
    return loads
end

# ╔═╡ 536bfb31-5629-4273-b0ec-0adf06d8bb62
md"""
### `lex_loads_improve`

Compares sorted load vectors in lexicographic order with a small heuristic comparison tolerance.
"""

# ╔═╡ 3186551c-93ef-4462-803f-1c1b0f061c8f
function lex_loads_improve(candidate, incumbent; tolerance=1e-10)
    for h in eachindex(candidate)
        candidate[h] < incumbent[h]-tolerance && return true
        candidate[h] > incumbent[h]+tolerance && return false
    end
    return false
end

# ╔═╡ 5e8da978-1cd6-4f7f-b72c-3df3ed413c2f
md"""
### `improve_route_pool!`

Uses a time-bounded greedy waypoint search to seed better feasible columns; does not certify optimality or prune the original domain.
"""

# ╔═╡ f137ffe6-5823-486f-bbed-f328dab305a8
function improve_route_pool!(data,pool;seconds=3.0,max_routes=16)
    selection = [only(ids) for ids in pool.by_demand]
    validation = validate_route_selection(data,pool,selection)
    seconds <= 0 && return (;validation,improvements=0)
    deadline = time_ns()+UInt64(round(seconds*1e9))
    loads = copy(validation.arc_loads)
    order = sortperm(data.v;rev=true)
    improvements = 0
    for pass in 1:4
        changed = false
        for d in order
            time_ns() >= deadline && return (;validation=validate_route_selection(data,pool,selection),improvements)
            old = sparse_route_loads(data,pool,d,pool.columns[selection[d]].path)
            base = loads-old
            best_sorted = sort(loads;rev=true)
            best_path = Int[]
            best_loads = loads
            source,target = data.sources[d],data.targets[d]
            for waypoint in vertices(data.graph)
                time_ns() >= deadline && break
                waypoint in (source,target) && continue
                data.counts[source,waypoint] > 0 && data.counts[waypoint,target] > 0 || continue
                path = [source,waypoint,target]
                candidate = base+sparse_route_loads(data,pool,d,path)
                candidate_sorted = sort(candidate;rev=true)
                if lex_loads_improve(candidate_sorted,best_sorted)
                    best_path,best_loads,best_sorted = path,candidate,candidate_sorted
                end
            end
            isempty(best_path) && continue
            column = add_route_column!(pool,data,d,best_path;max_routes)
            column == 0 && continue
            selection[d]=column
            loads=best_loads
            improvements+=1
            changed=true
        end
        changed || break
    end
    return (;validation=validate_route_selection(data,pool,selection),improvements)
end

# ╔═╡ 16cb313f-d096-4c3f-a798-3a3974b914a1
md"""
### `solve_route_lp!`

Solves restricted LPs, prices omitted routes, adds improving columns and records corrected global lower bounds. LP optimize! calls count toward the shared solve budget.
"""

# ╔═╡ af329d02-2385-412a-9f94-779afa8bae64
function solve_route_lp!(data,pool,k,locks; remaining,seed=1,rounds=40,max_routes=16,
        pricing_wall_limit=30.0,log_prefix="",max_binary_variables=2_000_000)
    HiGHS.Highs_resetGlobalScheduler(1)
    master = build_route_master(data,pool,k,locks;integer=false,time_limit=remaining,
        seed,max_binary_variables)
    elapsed = 0.0
    pricing_wall = 0.0
    bound = missing
    complete = false
    pricing_rows = NamedTuple[]
    converged = false
    for round in 1:rounds
        remaining-elapsed <= 1e-3 && break
        set_stage_time_limit!(master.model,:highs,remaining-elapsed)
        path = isempty(log_prefix) ? "" : log_prefix * "_pricing-" * lpad(round,2,'0') * ".log"
        set_stage_log!(master.model,:highs,path)
        write_solve_event(path,"start",remaining-elapsed,k)
        install_highs_deadline!(master.model,remaining-elapsed)
        seconds = try
            @elapsed optimize!(master.model)
        finally
            close_stage_log!(master.model,:highs)
        end
        write_solve_event(path,"end",max(0.0,remaining-elapsed-seconds),k)
        elapsed += seconds
        termination_status(master.model) == ORANGE_MOI.OPTIMAL || break
        dual_status(master.model) == ORANGE_MOI.FEASIBLE_POINT || break
        alpha = dual.(master.convexity)
        weights = -dual.(master.load_rows)
        minimum(weights;init=0.0) >= -1e-7 || error("Invalid pricing dual signs")
        projection_error = sum(data.v)*data.MaxSeg*sum(max.(-weights,0.0)./data.c)
        weights = max.(weights,0.0)
        dual_value = dual_objective_value(master.model)
        started = time()
        priced = minimum_segment_routes(data,weights;
            deadline=started+max(0.0,pricing_wall_limit-pricing_wall))
        pricing_wall += time()-started
        priced.complete || break
        complete = true
        reduced_costs = data.v .* priced.route_costs .- alpha
        candidate_bound = dual_value + sum(min(0.0,rc) for rc in reduced_costs)
        # Conservative numerical buffer for floating-point LP duals.
        candidate_bound -= projection_error + 1e-8 * (1+abs(dual_value)+sum(abs,weights)+sum(abs,alpha))
        bound = ismissing(bound) ? max(0.0,candidate_bound) : max(bound,candidate_bound)
        added = 0
        minimum_rc = minimum(reduced_costs;init=0.0)
        for d in eachindex(data.v)
            reduced_costs[d] < -1e-8 || continue
            length(pool.columns) >= max_binary_variables && break
            p = add_route_column!(pool,data,d,priced.paths[d];max_routes)
            if p > 0
                append_priced_variable!(master,pool,p)
                added += 1
            end
        end
        row = (stage=k,round=round,lp_solver="highs",optimize_seconds=seconds,
            global_bound=bound,min_reduced_cost=minimum_rc,added_routes=added,
            route_columns=length(pool.columns),pricing_wall_seconds=pricing_wall,
            log_file=isempty(path) ? "" : abspath(path))
        push!(pricing_rows,row)
        isempty(log_prefix) || append_result_csv(log_prefix * "_pricing.csv",row)
        converged = minimum_rc >= -1e-8
        (added == 0 || converged) && break
    end
    empty!(master.model)
    return (;bound,optimize_seconds=elapsed,pricing_wall_seconds=pricing_wall,complete,converged,pricing_rows)
end

# ╔═╡ 8e4569ee-47a2-4cbf-83b2-25cfa73bb5c8
md"""
### `route_cut_lower_bound`

Bounds MLU using total source/sink traffic divided by their outgoing/incoming physical capacity.
"""

# ╔═╡ df89efc2-fa06-43c1-bfdb-c6ea609b28cb
md"""
### Endpoint assignment lower bound — retain indivisible demands

For a source ``s`` and period ``t``, every valid route begins with one segment ``(s,j)``. The vector of physical loads on the active outgoing arcs produced by that first segment is nonnegative and componentwise no greater than the full route load. Keep only these initial contributions, drop Budget and all other physical rows, and let each originating demand select any reachable ``j``:

```math
L_{s,t}=\min_{z,y}\ z:\quad
\sum_j y_{dj}=1,\quad y_{dj}\in\{0,1\},\quad
\sum_{d:s_d=s}\sum_j\frac{v_{dt}r[s,j,a,t]}{c_a}y_{dj}\le z\ (a\in\delta^+(s)).
```

This is a relaxation of the original feasible set but retains the integer assignment of each demand. Incoming arcs at a target give the analogous last-segment relaxation. Identical coefficient vectors are deduplicated exactly. The maximum **solver lower bound** across visited endpoint problems is a valid global MLU lower bound even when endpoint solves time out. Unvisited groups still contribute their aggregate traffic/capacity cut bound. The original master remains unchanged; no endpoint optimizer incumbent is used as a bound. Endpoint optimize-call seconds are charged to the shared experiment budget and reported separately.
"""

# ╔═╡ ae65ba8d-0472-4b3c-86be-d0c16f88a187
function time01_endpoint_bound(data;time_limit=20.,seed=1,threads=1,max_groups=48,time0=false)
    n=length(data.node_ids);groups=NamedTuple[]
    times=time0 ? (0:0) : (0:1)
    for t in times,direction in (:source,:target),vertex in 1:n
        demands=findall((direction==:source ? data.sources : data.targets).==vertex)
        isempty(demands) && continue
        active=time0 ? eachindex(data.arcs) : data.periods[t+1].active_arc_indices
        arcs=[a for a in active if (direction==:source ? data.arcs[a][1] : data.arcs[a][2])==vertex]
        isempty(arcs) && continue
        floor=sum(time0 ? data.v[d] : data.v[d,t] for d in demands)/sum(data.c[a] for a in arcs)
        push!(groups,(;t,direction,vertex,demands,arcs,floor))
    end
    sort!(groups;by=g->g.floor,rev=true)
    bound=isempty(groups) ? 0. : maximum(g.floor for g in groups)
    seconds=0.;nodes=0;visited=0
    for g in first(groups,min(max_groups,length(groups)))
        remaining=time_limit-seconds;remaining<=.01 && break
        vectors=Vector{Float64}[];seen=Set{Tuple}()
        for waypoint in 1:n
            waypoint==g.vertex && continue
            i,j=g.direction==:source ? (g.vertex,waypoint) : (waypoint,g.vertex)
            (time0 ? data.counts[i,j] : data.periods[g.t+1].counts[i,j])>0 || continue
            vector=[(time0 ? data.r[i,j,a] : data.r[i,j,a,g.t])/data.c[a] for a in g.arcs]
            key=Tuple(vector)
            key in seen && continue
            push!(seen,key);push!(vectors,vector)
        end
        isempty(vectors) && continue
        model=create_time0_optimizer(:highs;time_limit=min(1.,remaining),seed,threads=1)
        set_string_names_on_creation(model,false)
        try
            y=@variable(model,[1:length(g.demands),1:length(vectors)],binary=true)
            z=@variable(model,lower_bound=0.)
            @constraint(model,[d in eachindex(g.demands)],sum(y[d,p] for p in eachindex(vectors))==1)
            volumes=[time0 ? data.v[d] : data.v[d,g.t] for d in g.demands]
            @constraint(model,[a in eachindex(g.arcs)],sum(volumes[d]*vectors[p][a]*y[d,p] for d in eachindex(g.demands),p in eachindex(vectors))<=z)
            @objective(model,Min,1.0*z)
            install_highs_deadline!(model,min(1.,remaining))
            seconds+=@elapsed optimize!(model);nodes+=node_count(model);visited+=1
            lower=objective_bound(model)
            isfinite(lower)&&abs(lower)<1e19 && (bound=max(bound,lower-1e-7*(1+abs(lower))))
        finally
            empty!(model)
        end
    end
    return (;bound,seconds,nodes,visited)
end

# ╔═╡ 91f7c7d3-c219-40e3-bb4c-7517478f94b8
function route_cut_lower_bound(data)
    outgoing_capacity = zeros(nv(data.graph))
    incoming_capacity = zeros(nv(data.graph))
    outgoing_traffic = zeros(nv(data.graph))
    incoming_traffic = zeros(nv(data.graph))
    for (a,(i,j)) in enumerate(data.arcs)
        outgoing_capacity[i] += data.c[a]
        incoming_capacity[j] += data.c[a]
    end
    for d in eachindex(data.v)
        outgoing_traffic[data.sources[d]] += data.v[d]
        incoming_traffic[data.targets[d]] += data.v[d]
    end
    ratios = [0.0]
    for i in vertices(data.graph)
        outgoing_capacity[i] > 0 && push!(ratios,outgoing_traffic[i]/outgoing_capacity[i])
        incoming_capacity[i] > 0 && push!(ratios,incoming_traffic[i]/incoming_capacity[i])
    end
    return maximum(ratios)
end

# ╔═╡ 82029e20-1987-451e-a27f-bd24c61809c0
md"""
### `solve_time0_routes`

Coordinates warm start, pricing and restricted integer solves, retaining global bounds and certifying only justified lexicographic stages.
"""

# ╔═╡ 1c462a22-e6f0-4ef7-8c8b-560780682355
md"""
### `route_pool_complete`

Checks whether every valid simple route is already stored, returning false immediately on the first omitted route. Only a complete pool makes its restricted MIP bound a global bound. It is mainly useful for tiny verification examples.
"""

# ╔═╡ e80fae9f-d0c0-4be7-b391-dd8327236ced
function route_pool_complete(data,pool)
    for d in eachindex(data.v)
        target=data.targets[d]
        stack=[[data.sources[d]]]
        while !isempty(stack)
            path=pop!(stack)
            last(path)==target && (Tuple(path) in pool.keys[d] || return false; continue)
            length(path)-1 >= data.MaxSeg && continue
            current=last(path)
            for next_vertex in vertices(data.graph)
                next_vertex in path && continue
                data.counts[current,next_vertex] > 0 && data.counts[next_vertex,target] > 0 || continue
                push!(stack,[path;next_vertex])
            end
        end
    end
    return true
end

# ╔═╡ cf434e7f-4d91-4dc1-8442-fe30f9e6af52
md"""
### `expand_route_pool!` — Continue searching beyond an LP-optimal route pool

A persistent enumeration cursor visits simple waypoint sequences in increasing segment count. Each call adds a bounded batch per demand, including routes with nonnegative LP reduced cost that may help an integer solution. Cyclic vertex ordering spreads early alternatives across demands reproducibly. All endpoint, reachability and MaxSeg checks remain active. No route is excluded from the original domain; no upper bound or optimality claim comes from enumeration alone. The cursor uses constant storage per demand rather than storing the exponential path tree.
"""

# ╔═╡ ef4be839-72c5-46f0-a574-c18135b6eb47
function expand_route_pool!(data,pool,ranks,hops;max_routes,seed=1,per_demand=2,
        deadline=Inf,max_binary_variables=2_000_000)
    added=0
    for d in eachindex(data.v)
        time() >= deadline && break
        length(pool.columns) >= max_binary_variables && break
        length(pool.by_demand[d]) >= max_routes && continue
        source,target=data.sources[d],data.targets[d]
        nodes=[i for i in vertices(data.graph) if i != source && i != target]
        isempty(nodes) && (hops[d]=data.MaxSeg;continue)
        offset=mod(seed+d-1,length(nodes))
        nodes=circshift(nodes,offset)
        accepted=0
        attempts=0
        while hops[d] < data.MaxSeg && accepted < per_demand && attempts < 256
            time() >= deadline && break
            length(pool.columns) >= max_binary_variables && break
            length(pool.by_demand[d]) >= max_routes && break
            count=big(length(nodes))^hops[d]
            if ranks[d] >= count
                ranks[d]=0
                hops[d]+=1
                continue
            end
            rank=ranks[d]
            ranks[d]+=1
            attempts+=1
            path=Int[source]
            for h in 1:hops[d]
                digit=Int(mod(rank,length(nodes)))+1
                push!(path,nodes[digit])
                rank=div(rank,length(nodes))
            end
            push!(path,target)
            length(unique(path)) == length(path) || continue
            all(data.counts[path[h],path[h+1]] > 0 for h in 1:length(path)-1) || continue
            column=add_route_column!(pool,data,d,path;max_routes)
            if column > 0
                added+=1
                accepted+=1
            end
        end
    end
    return (;added,exhausted=all(hops .>= data.MaxSeg))
end

# ╔═╡ de3e2d40-0941-490c-983b-d614c4090f41
function solve_time0_routes(data; solver=:highs,instance="instance",run=1,time_limit=1800.0,
        seed=1,threads=1,max_binary_variables=2_000_000,log_file="",solution_file="",
        console=false,lock_tolerance=1e-7,max_routes_per_demand=16,pricing_rounds=40,
        pricing_time_limit=30.0,proof_tolerance=1e-7,
        highs_profile=:default,target_gap=0.10,deadline_callback=true,warm_start_seconds=3.0,
        stage_observer=nothing)
    isfinite(time_limit) && time_limit > 0 || error("Invalid time limit")
    max_routes_per_demand >= 1 && pricing_rounds >= 1 || error("Invalid route settings")
    pricing_time_limit >= 0 && proof_tolerance >= 0 || error("Invalid pricing or proof tolerance")
    started_wall = time()
    pool = initial_route_pool(data)
    heuristic_started = time_ns()
    warm = improve_route_pool!(data,pool;seconds=warm_start_seconds,max_routes=max_routes_per_demand)
    heuristic_seconds = (time_ns()-heuristic_started)/1e9
    validation = warm.validation
    endpoint=time01_endpoint_bound(data;time0=true,time_limit=min(30.,.1time_limit),seed,threads)
    first_bound = max(route_cut_lower_bound(data),endpoint.bound)
    active_bound = first_bound
    completed = 0
    active_stage = 1
    total_nodes = endpoint.nodes
    elapsed = endpoint.seconds
    lp_seconds = endpoint.seconds
    pricing_wall = 0.0
    locks = Float64[]
    certified_bounds = Float64[]
    termination = "NOT_RUN"
    primal = "FEASIBLE_POINT"
    root = isempty(log_file) ? "" : replace(log_file,r"\.log$" => "")
    stage_csv = isempty(root) ? "" : root * "_stages.csv"
    !isempty(stage_csv) && isfile(stage_csv) && rm(stage_csv)
    write_solution_checkpoint(solution_file,data,validation;solver,instance,run,completed,
        active_stage,lower_bound=first_bound,stage_lower_bound=active_bound,lock_tolerance,
        formulation="routes",target_gap,proof_tolerance)
    k=1
    stage_cycle=0
    stage_bound=0.0
    pool_limit=max_routes_per_demand
    ranks=fill(big(0),length(data.v))
    hops=ones(Int,length(data.v))
    search_deadline=started_wall+time_limit+max(30.0,0.1*time_limit)
    while k <= length(data.arcs)
        active_stage = k
        remaining = time_limit-elapsed
        remaining <= 1e-3 && (termination="TIME_LIMIT";break)
        time() >= search_deadline && (termination="SEARCH_WALL_LIMIT";break)
        stage_cycle+=1
        added_routes=0
        if stage_cycle > 1
            pool_limit=min(max_binary_variables,max(pool_limit+2,2*pool_limit))
            expansion=expand_route_pool!(data,pool,ranks,hops;max_routes=pool_limit,seed,
                deadline=min(search_deadline,time()+5.0),max_binary_variables)
            added_routes=expansion.added
            if added_routes == 0 && length(pool.columns) >= max_binary_variables
                termination="ROUTE_POOL_LIMIT"
                break
            end
        end
        prefix = isempty(root) ? "" : root * "_stage-" * lpad(k,3,'0') * "_cycle-" * lpad(stage_cycle,3,'0')
        lp = solve_route_lp!(data,pool,k,locks;remaining=min(remaining*0.35,60.0),seed,
            rounds=pricing_rounds,max_routes=pool_limit,
            pricing_wall_limit=min(pricing_time_limit,max(0.0,search_deadline-time())),log_prefix=prefix,
            max_binary_variables)
        elapsed += lp.optimize_seconds
        lp_seconds += lp.optimize_seconds
        pricing_wall += lp.pricing_wall_seconds
        active_bound = max(stage_bound,k == 1 ? first_bound : certified_bounds[end],
            ismissing(lp.bound) ? 0.0 : lp.bound)
        k == 1 && (first_bound=max(first_bound,active_bound))
        current_value = sum(sort(validation.arc_loads;rev=true)[1:k])
        write_solution_checkpoint(solution_file,data,validation;solver,instance,run,completed,
            active_stage,lower_bound=first_bound,stage_lower_bound=active_bound,lock_tolerance,
            formulation="routes",target_gap,proof_tolerance)
        nodes = 0
        restricted_bound = missing
        mip_seconds = 0.0
        mip_status = "NOT_NEEDED"
        remaining = time_limit-elapsed
        if current_value-active_bound > proof_tolerance && remaining > 1e-3
            slice=min(remaining,60.0)
            master = build_route_master(data,pool,k,locks;solver,time_limit=slice,
                seed,threads,max_binary_variables,console,highs_profile)
            start_route_master!(master,validation)
            path = isempty(prefix) ? "" : prefix * ".log"
            set_stage_time_limit!(master.model,solver,slice)
            set_stage_log!(master.model,solver,path;console)
            write_solve_event(path,"start",remaining,k)
            solver == :highs && install_highs_deadline!(master.model,slice;enabled=deadline_callback)
            mip_seconds = try
                @elapsed optimize!(master.model)
            finally
                close_stage_log!(master.model,solver)
            end
            write_solve_event(path,"end",max(0.0,time_limit-elapsed-mip_seconds),k)
            isnothing(stage_observer) || stage_observer(master.model,solver,k,path)
            elapsed += mip_seconds
            mip_status = string(termination_status(master.model))
            nodes = node_count(master.model)
            total_nodes += nodes
            candidate_bound = objective_bound(master.model)
            restricted_bound = isfinite(candidate_bound) ? candidate_bound : missing
            if !ismissing(restricted_bound) && route_pool_complete(data,pool)
                active_bound=max(active_bound,restricted_bound)
                k==1 && (first_bound=max(first_bound,active_bound))
            end
            if primal_status(master.model) == ORANGE_MOI.FEASIBLE_POINT
                selection = Int[]
                for d in eachindex(data.v)
                    chosen = [p for p in pool.by_demand[d] if value(master.y[p]) > 0.5]
                    length(chosen) == 1 || error("Invalid integer route selection")
                    push!(selection,only(chosen))
                end
                all(abs(value(y)-round(value(y))) <= 1e-5 for y in master.y) || error("Nonintegral route incumbent")
                candidate = validate_route_selection(data,pool,selection)
                candidate_loads = sort(candidate.arc_loads;rev=true)
                all(sum(candidate_loads[1:h]) <= locks[h]+1e-5 for h in eachindex(locks)) ||
                    error("Incumbent violates an earlier lexicographic lock")
                candidate_value = sum(sort(candidate.arc_loads;rev=true)[1:k])
                if candidate_value <= current_value + 1e-7
                    validation = candidate
                    current_value = candidate_value
                end
            end
            empty!(master.model)
        end
        active_bound <= current_value + proof_tolerance || error("Computed global bound exceeds validated incumbent")
        certified = current_value-active_bound <= proof_tolerance
        row = (solver=String(solver),solver_version=orange_solver_version(solver),stage=k,cycle=stage_cycle,
            added_enumerated_routes=added_routes,pool_limit=pool_limit,
            objective="sum_of_largest_$(k)_loads",formulation="routes",route_incumbent=current_value,
            lower_bound=active_bound,gap=experiment_gap(current_value,active_bound),
            restricted_mip_bound=restricted_bound,restricted_mip_termination=mip_status,
            globally_certified=certified,route_columns=length(pool.columns),
            lp_optimize_seconds=lp.optimize_seconds,mip_optimize_seconds=mip_seconds,
            cumulative_optimize_seconds=elapsed,pricing_wall_seconds=lp.pricing_wall_seconds,
            pricing_oracle_complete=lp.complete,column_generation_converged=lp.converged,nodes=nodes,
            log_file=isempty(prefix) || !isfile(prefix * ".log") ? "" : abspath(prefix * ".log"))
        isempty(stage_csv) || append_result_csv(stage_csv,row)
        if !isempty(stage_csv)
            println(instance," | stage=",k," cycle=",stage_cycle," routes=",length(pool.columns),
                " value=",current_value," global_bound=",active_bound,
                " certified=",certified," optimize_seconds=",elapsed)
            flush(stdout)
        end
        if certified
            completed = k
            push!(locks,current_value+lock_tolerance)
            push!(certified_bounds,active_bound)
            termination = "OPTIMAL"
            k+=1
            stage_cycle=0
            stage_bound=0.0
        else
            stage_bound=active_bound
            termination="TIME_LIMIT"
        end
        write_solution_checkpoint(solution_file,data,validation;solver,instance,run,completed,
            active_stage,lower_bound=first_bound,stage_lower_bound=active_bound,lock_tolerance,
            formulation="routes",target_gap,proof_tolerance)
    end
    sorted_loads = sort(validation.arc_loads;rev=true)
    status = completed == length(data.arcs) ? "Optimal" : "Not Optimal"
    mlu_gap = experiment_gap(validation.maximum_load,first_bound)
    active_gap = experiment_gap(sum(sorted_loads[1:active_stage]),active_bound)
    quality = approximation_quality(true,mlu_gap,active_gap,completed,length(data.arcs),target_gap)
    write_solution_checkpoint(solution_file,data,validation;solver,instance,run,completed,
        active_stage,lower_bound=first_bound,stage_lower_bound=active_bound,lock_tolerance,
        formulation="routes",target_gap,proof_tolerance,termination,status)

    return (instance=String(instance),run=run,time=0,solver=String(solver),
        solver_version=orange_solver_version(solver),vertices=nv(data.graph),links=length(data.arcs),
        demands=length(data.v),objective=validation.maximum_load,lower_bound=first_bound,
        cpu_time_seconds=elapsed,status=status,termination=termination,primal_status=primal,
        gap=mlu_gap,nodes=total_nodes,
        feasible=true,validated=true,checked_mlu=validation.maximum_load,
        lex_completed_stages=completed,lex_total_stages=length(data.arcs),active_stage=active_stage,
        stage_objective=sum(sorted_loads[1:active_stage]),stage_lower_bound=active_bound,
        stage_gap=active_gap,highs_profile=String(highs_profile),target_gap=quality.target_gap,
        mlu_target_met=quality.mlu_target_met,active_stage_target_met=quality.active_stage_target_met,
        quality_status=quality.quality_status,deadline_callback=deadline_callback,
        sorted_loads_json=JSON3.write(sorted_loads),time_limit=Float64(time_limit),seed=seed,threads=threads,
        objective_mode="lexicographic_sorted_loads",splitting=String(data.splitting),
        lock_tolerance=lock_tolerance,binary_variables=length(pool.columns),
        log_file=isempty(stage_csv) ? "" : abspath(stage_csv),
        solution_file=isempty(solution_file) ? "" : abspath(solution_file),error="",
        formulation="routes",potential_compact_variables=length(data.v)*length(data.segments),
        candidate_routes=length(pool.columns),pricing_lp_solver="highs",
        pricing_optimize_seconds=lp_seconds,mip_optimize_seconds=elapsed-lp_seconds,
        pricing_wall_seconds=pricing_wall,wall_time_seconds=time()-started_wall,
        bound_scope="global",proof_tolerance=proof_tolerance,
        heuristic_seconds=heuristic_seconds,heuristic_improvements=warm.improvements)
end

# ╔═╡ 79b800a9-48e4-45a8-b597-9b8076728465
md"""
### `normalize_time0_result`

Uses the same CSV column order for compact, route-based and failed runs. Missing diagnostics remain missing rather than shifting columns.
"""

# ╔═╡ b3659101-8e23-406c-96ca-a80b36579c7c
function normalize_time0_result(row)
    fields = (:instance,:run,:time,:solver,:solver_version,:vertices,:links,:demands,:objective,:lower_bound,:cpu_time_seconds,:status,:termination,:primal_status,:gap,:nodes,:feasible,:validated,:checked_mlu,:lex_completed_stages,:lex_total_stages,:active_stage,:stage_objective,:stage_lower_bound,:stage_gap,:highs_profile,:target_gap,:mlu_target_met,:active_stage_target_met,:quality_status,:deadline_callback,:sorted_loads_json,:time_limit,:seed,:threads,:objective_mode,:splitting,:lock_tolerance,:binary_variables,:log_file,:solution_file,:error,:formulation,:bound_scope,:potential_compact_variables,:candidate_routes,:pricing_lp_solver,:pricing_optimize_seconds,:mip_optimize_seconds,:pricing_wall_seconds,:wall_time_seconds,:proof_tolerance,:heuristic_seconds,:heuristic_improvements)
    return (; (name => (hasproperty(row,name) ? getproperty(row,name) : missing) for name in fields)...)
end

# ╔═╡ f1b17671-4b54-4b2b-9231-20300509c373
function solve_time0(data; solver=:highs, formulation=:auto, compact_threshold=100_000,
        max_routes_per_demand=16,pricing_rounds=40,pricing_time_limit=30.0,
        proof_tolerance=1e-7,warm_start_seconds=3.0,highs_profile=:auto,settings...)
    lock(ORANGE_SOLVER_LOCK)
    try
        solver in (:scip,:highs) || error("Unknown solver $solver; choose :scip or :highs")
        solver == :highs && HiGHS.Highs_resetGlobalScheduler(1)
        formulation in (:auto,:compact,:routes) || error("Unknown formulation $formulation")
        chosen = formulation == :auto ?
            (length(data.v)*length(data.segments) > compact_threshold ? :routes : :compact) : formulation
        selected_profile = highs_profile == :auto ?
            (solver == :highs && chosen == :compact ? :incumbent : :default) : highs_profile
        if chosen == :routes
            result = solve_time0_routes(data;solver,max_routes_per_demand,pricing_rounds,
                pricing_time_limit,proof_tolerance,warm_start_seconds,highs_profile=selected_profile,settings...)
            return normalize_time0_result(result)
        end
        result = solve_time0_serial(data;solver,highs_profile=selected_profile,settings...)
        return normalize_time0_result(merge(result,(formulation="compact",bound_scope="global")))
    finally
        unlock(ORANGE_SOLVER_LOCK)
    end
end

# ╔═╡ c77ef705-5cf7-4fda-ac94-508bf8193134
md"""
## Display the route formulation on the verification example

The route and compact formulations must produce the same sorted vector. This tiny instance has a complete generated pool, so all four stages can be certified. Real instances may stop at a remaining global LP/integer gap.
"""

# ╔═╡ 534fb5b2-9055-42ea-ac95-68d7919bd7fc
route_demo_result = solve_time0(lex_demo_data;solver=:highs,formulation=:routes,time_limit=5.0)

# ╔═╡ 8b667b30-fffd-4231-97c4-a300612c4ffd
(solver=route_demo_result.solver, formulation=route_demo_result.formulation,
    sorted_loads=JSON3.read(route_demo_result.sorted_loads_json),
    status=route_demo_result.status, certified_stages=route_demo_result.lex_completed_stages,
    mlu_gap=route_demo_result.gap,quality=route_demo_result.quality_status,
    route_variables=route_demo_result.candidate_routes,
    original_potential_binaries=route_demo_result.potential_compact_variables)

# ╔═╡ 1cbf9a85-1cb6-4d46-80cc-fecdd47e0ddf
lex_demo_result = solve_time0(lex_demo_data; solver=:scip, instance="lex-demo", time_limit=5.0,
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
function run_seta_experiments(; solver=:highs, instances=1:20, runs=10, time_limit=1800.0,
        output_dir=nothing, seed_base=1000, threads=1,run_start=1,
        splitting=:ecmp, max_binary_variables=2_000_000, console=false, lock_tolerance=1e-7,
        highs_profile=:auto, target_gap=0.10, deadline_callback=true,
        formulation=:auto,compact_threshold=100_000,max_routes_per_demand=16,
        pricing_rounds=40,pricing_time_limit=30.0,proof_tolerance=1e-7,warm_start_seconds=3.0)
    solver in (:scip,:highs) || error("Unknown solver $solver; choose :scip or :highs")
    output_dir = isnothing(output_dir) ? joinpath(@__DIR__,"results","time0_lex_$(solver)") : abspath(output_dir)
    runs >= 1 && run_start>=1 || error("runs and run_start must be positive")
    isfinite(time_limit) && time_limit > 0 || error("Invalid time limit")
    ids = collect(Int, instances)
    !isempty(ids) && all(i -> 1 <= i <= 20, ids) && length(unique(ids)) == length(ids) || error("Invalid instance IDs")
    mkpath(output_dir)
    config = (schema_version=5, route_search_policy="expand_until_budget", route_mip_slice_seconds=60.0, formulation=String(formulation),compact_threshold=compact_threshold,
        max_routes_per_demand=max_routes_per_demand,pricing_rounds=pricing_rounds,
        pricing_time_limit=pricing_time_limit,proof_tolerance=proof_tolerance,warm_start_seconds=warm_start_seconds, highs_profile=String(highs_profile), target_gap=Float64(target_gap),
        deadline_callback=deadline_callback, solver=String(solver),solver_version=orange_solver_version(solver),
        instances=ids, runs=runs,run_start, time_limit=Float64(time_limit), seed_base=seed_base,
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
        for run in run_start:run_start+runs-1
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
                        max_binary_variables, log_file, solution_file, console, lock_tolerance,
                        highs_profile, target_gap, deadline_callback, formulation,compact_threshold,
                        max_routes_per_demand,pricing_rounds,pricing_time_limit,proof_tolerance,warm_start_seconds)
                catch exception
                    exception isa InterruptException && rethrow()
                    message = sprint(showerror,exception)
                    row = normalize_time0_result(experiment_error_row(data,instance,run,time_limit,seed,threads,log_file,message,lock_tolerance,solver;highs_profile,target_gap,deadline_callback))
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

# ╔═╡ bc2aa034-eec5-4be9-8e67-f42e53274e97
md"""
# Data at time 1 and the two-period model

Only directed link IDs listed at time 1 are removed: G(1)=(V,A\q(1)). The reverse link remains available unless its own ID is listed. Original arc IDs and array positions are retained; r[i,j,a,1]=0 on a removed physical arc. Shortest-path distances and ECMP fractions are recomputed, rather than copied from time 0. Traffic uses the second JSON entry v[d,1]; capacities and MaxSeg are unchanged.

### Period-indexed Data equations

Let F_1 contain the directed arc IDs listed in the time-1 intervention. Retaining the nominal arc index set A in all arrays gives

```math
A_0=A,\qquad A_1=A\setminus F_1,\qquad G_t=(V,A_t),\qquad t\in\{0,1\}.
```

For a reachable ordered pair i,j with i different from j, define the shortest-path next-hop set using distances computed on G_t:

```math
N_t(i,j)=\{k:(i,k)\in A_t,\ w_{ik}+\operatorname{dist}_t(k,j)=\operatorname{dist}_t(i,j)\}.
```

Next-hop ECMP divides equally at each router, so the physical-arc fractions satisfy

```math
r_{jj a t}=0,\qquad
r_{ij a t}=\frac{1}{|N_t(i,j)|}\sum_{k\in N_t(i,j)}
\left(\mathbf1_{a=(i,k)}+r_{kj a t}\right).
```

This recurrence applies to reachable pairs; unreachable segments are excluded from the model. Positive link metrics make the shortest-path recursion acyclic. For every failed physical arc, r[i,j,a,1] is zero. The stored capacity c[a] remains the original capacity, so no division by a zero failed-arc capacity is introduced.

```math
v_{d,0}=\text{tm.demands[d].v[1]},\qquad
v_{d,1}=\text{tm.demands[d].v[2]},\qquad
K=\text{scenario.max\_segments},\qquad
\kappa_1=\text{scenario.budget entry at }t=1.
```

JSON IDs are mapped to Julia indices; the displayed arrays use `r[i,j,a,t]`, `v[d,t]`, and `c[a]`. The following functions are independent notebook-level definitions. The displayed example comes from the official subject, not a generated replacement for SetA.
"""

# ╔═╡ 0b8dc725-5f9e-4bb8-b28f-39ea4d795bec
begin
struct TimeRoutingRatios <: AbstractArray{Float64,4}
    periods::Vector{RoutingRatios}
end
Base.size(r::TimeRoutingRatios)=(r.periods[1].n,r.periods[1].n,size(r.periods[1].values,2),length(r.periods))
Base.axes(r::TimeRoutingRatios)=(Base.OneTo(size(r,1)),Base.OneTo(size(r,2)),Base.OneTo(size(r,3)),0:length(r.periods)-1)
function Base.getindex(r::TimeRoutingRatios,i::Int,j::Int,a::Int,t::Int)
    checkbounds(r,i,j,a,t)
    return r.periods[t+1][i,j,a,0]
end
end

# ╔═╡ 2b4d01b6-060a-4a1f-a746-b11e7600a3c9
md"""
### `period_graph_data` — rebuild one period on stable physical-arc indices

Receives nominal Data, failed arc IDs, period traffic and a time label. Calculates routing on the active graph only, then embeds the sparse coefficients back into the original physical-arc columns. It validates that every demand remains reachable. No reverse failure or cumulative failure is inferred.
"""

# ╔═╡ 32f0ec3c-773f-4935-9c7c-c6efa67af057
function period_graph_data(base,failed_ids,volumes,time;splitting=:ecmp)
    unknown=setdiff(Set(failed_ids),Set(base.arc_ids))
    isempty(unknown) || error("Unknown failed arc IDs: $unknown")
    active=[a for a in eachindex(base.arcs) if !(base.arc_ids[a] in failed_ids)]
    graph=SimpleDiGraph(length(base.node_ids))
    for a in active
        add_edge!(graph,base.arcs[a]...)
    end
    weights,scale=integer_metric_matrix(base.arcs[active],base.metric[active],nv(graph))
    routing=routing_ratios(graph,weights,base.arcs[active];splitting)
    values=spzeros(nv(graph)^2,length(base.arcs))
    values[:,active]=routing.r.values
    r=RoutingRatios(values,nv(graph))
    all(routing.counts[s,t]>0 for (s,t) in zip(base.sources,base.targets)) || error("Unreachable demand at time $time")
    all(x->isfinite(x)&&x>=0,volumes) || error("Invalid traffic at time $time")
    distances=[routing.counts[i,j]>0 ? Float64(BigFloat(routing.distances[i,j])/BigFloat(scale)) : Inf
        for i in 1:nv(graph),j in 1:nv(graph)]
    segments=[(i,j) for i in 1:nv(graph) for j in 1:nv(graph) if i!=j && routing.counts[i,j]>0]
    return merge(base,(;graph,r,counts=routing.counts,distances,segments,v=Float64.(volumes),time,
        active_arc_indices=active,failed_arc_ids=sort(collect(failed_ids))))
end

# ╔═╡ 15eb46ca-9e71-4253-88f5-1a27e44cbf30
md"""
### `load_time01_data` — prepare both periods from the three original JSON files

Loads nominal Data, validates the second traffic entry, reads the time-1 intervention and integer Budget, and calls the period builder. Missing Budget is rejected. The result exposes `r[i,j,a,t]` and `v[d,t]` with time axis `0:1`, plus both graphs, original IDs and reachability matrices. This function does not solve an optimization model.
"""

# ╔═╡ 77d88db4-3a6d-43ec-bd57-89a3ce8a614b
function load_time01_data(prefix::AbstractString;splitting=:ecmp)
    base=load_data(prefix;splitting)
    tm=JSON3.read(read(prefix*"-tm.json",String))
    scenario=JSON3.read(read(prefix*"-scenario.json",String))
    tm.num_time_slots>=2 || error("Time 1 is missing")
    failed=Set{Int}()
    for event in scenario.interventions
        Int(event.t)==1 || continue
        union!(failed,Int.(event.links))
    end
    budgets=[Int(b.value) for b in scenario.budget if Int(b.t)==1]
    length(budgets)==1 && only(budgets)>=0 || error("Expected one nonnegative time-1 Budget")
    volumes=Float64[d.v[2] for d in tm.demands]
    nominal=merge(base,(active_arc_indices=collect(eachindex(base.arcs)),failed_arc_ids=Int[]))
    next=period_graph_data(base,failed,volumes,1;splitting)
    v=JuMP.Containers.DenseAxisArray(hcat(base.v,volumes),eachindex(base.v),0:1)
    r=TimeRoutingRatios([nominal.r,next.r])
    return (;periods=[nominal,next],graphs=[nominal.graph,next.graph],r,v,
        budget=only(budgets),MaxSeg=base.MaxSeg,node_ids=base.node_ids,arc_ids=base.arc_ids,
        arcs=base.arcs,c=base.c,sources=base.sources,targets=base.targets,demand_ids=base.demand_ids,
        splitting,times=0:1,prefix=abspath(prefix))
end

# ╔═╡ bd9a019c-a5f2-49d6-9866-ffe672b17684
md"""
## Budget and original mathematical constraints

For each demand and period, let x[d,i,j,t] indicate whether ordered segment (i,j) is present. The original conservation, segment limit and physical-load equations remain:

```math
\sum_j x_{ij}^{dt}-\sum_j x_{ji}^{dt}=\mathbf1_{i=s_d}-\mathbf1_{i=t_d},\qquad
\sum_{i\ne j}x_{ij}^{dt}\le K,\qquad x_{ij}^{dt}\in\{0,1\},
\quad\lambda_{at}\ge\frac{1}{c_a}\sum_d\sum_{i\ne j}v_{dt}r_{ijat}x_{ij}^{dt}.
```

Unreachable segments are excluded. Removed physical arcs have load zero. For the single transition, introduce continuous h[d,i,j] in [0,1]:

```math
h_{dij}\ge x_{ij}^{d1}-x_{ij}^{d0},\quad
h_{dij}\ge x_{ij}^{d0}-x_{ij}^{d1},\quad
\sum_d\sum_{i\ne j}h_{dij}\le\kappa(1).
```

For binary x, this is exactly the original absolute-difference Budget. A direct segment (s,t) replaced by (s,w),(w,t) costs 3. Reordering waypoints can change the segment set even if the waypoint set stays unchanged.

Sort all 2|A| loads across **both** periods together and minimize that vector lexicographically using the existing sequential top-k objectives. It is not two separate period optimizations. The inactive arc/time entries are canonical zeros and remain in the full vector.

### Column representation and scope

One column is a complete connected segment sequence for one demand at one period. It satisfies conservation and MaxSeg by construction. Selecting exactly one column defines the original x as its segment-incidence vector. The Budget is imposed across periods on these incidences, not on column IDs.

For the complete valid route domain P_dt, let delta_ijp be 1 precisely when route p contains ordered segment (i,j). The change of variables is

```math
\sum_{p\in P_{dt}}y_{dpt}=1,\qquad y_{dpt}\in\{0,1\},\qquad
x_{ij}^{dt}=\sum_{p\in P_{dt}}\delta_{ijp}y_{dpt}.
```

The implementation allocates only generated columns. Accordingly, its current feasible domain can be restricted even though each stored column obeys the original routing constraints; global certification needs the pricing bound or full enumeration.

### Joint lexicographic objective and numerical locks

Let M=2|A| and let ell_(1) through ell_(M) denote all physical arc/time loads sorted in nonincreasing order, including failed-arc zeros:

```math
\operatorname{lexmin}\left(\ell_{(1)},\ldots,\ell_{(M)}\right),\qquad
F_k(\lambda)=\sum_{q=1}^{k}\ell_{(q)}.
```

At stage k, minimize F_k while retaining the previously certified F_j values. The epigraph used by `add_lexicographic_stage!` is

```math
F_k(\lambda)=\min_{\eta\in\mathbb R,\ s\ge0}
\left\{k\eta+\sum_{a\in A}\sum_{t=0}^{1}s_{at}:
 s_{at}\ge\lambda_{at}-\eta\right\}.
```

The stored loads are nonnegative, so restricting eta to be nonnegative is also valid. In exact arithmetic earlier locks are F_j(lambda) <= F_j*. In the implementation they allow `lock_tolerance`, and stage advancement requires the incumbent top-k value minus a valid global lower bound to be at most `proof_tolerance`. Defaults here are 1e-7 and 2e-6 respectively. Therefore “certified” is a numerical statement at the reported tolerances. A 10% MLU gap is only a reporting target and does not certify the remaining vector or release earlier locks.

Unlike the time-0 reduction, repeated waypoints are not automatically deleted here. Columns may revisit a vertex, but cannot repeat the same ordered segment: this retains the original binary-segment load accounting. No MTZ/simple-waypoint restriction is imported from the time-0 model. A generated pool is restricted; its native integer bound is global only when enumeration is complete. This model never labels an incomplete-pool optimal solve globally Optimal.
"""

# ╔═╡ 91725283-c491-4833-8761-f3392001721e
md"""
### `segment_change_count` — compute the original reconfiguration cost

Receives two complete vertex sequences including endpoints. Returns the size of the symmetric difference of their ordered segment sets. It is used for independent validation and for Budget examples.
"""

# ╔═╡ 5cea359a-93dc-484a-b9fa-7506880410cf
function segment_change_count(path0,path1)
    return length(symdiff(Set(zip(path0,path0[2:end])),Set(zip(path1,path1[2:end]))))
end

# ╔═╡ f21f8c26-ef05-420d-9084-f9e19c57ef81
md"""
### `add_time01_column!` — validate and store a segment sequence

Checks endpoints, segment count, reachability, distinct consecutive vertices and absence of repeated ordered segments. Stores its physical-load vector and ordered segment-incidence keys. Vertex revisits are permitted; malformed/disconnected routes are not.
"""

# ╔═╡ a7f93306-bc7c-45f6-a236-fc02a64a4dcd
function add_time01_column!(columns,keys,data,q,path;max_routes=typemax(Int))
    D=length(data.sources);d=mod(q-1,D)+1;t=div(q-1,D)
    key=Tuple(path)
    key in keys[q] && return 0
    length(keys[q])>=max_routes && return 0
    first(path)==data.sources[d] && last(path)==data.targets[d] || error("Wrong temporal route endpoints")
    length(path)-1<=data.MaxSeg || error("Too many temporal segments")
    pairs=collect(zip(path,path[2:end]))
    all(i!=j for (i,j) in pairs) || error("Zero-length segment")
    length(unique(pairs))==length(pairs) || error("Repeated ordered segment")
    period=data.periods[t+1]
    all(period.counts[i,j]>0 for (i,j) in pairs) || error("Unreachable temporal segment")
    loads=zeros(length(data.arcs))
    for (i,j) in pairs,a in eachindex(loads)
        loads[a]+=data.v[d,t]*data.r[i,j,a,t]/data.c[a]
    end
    n=length(data.node_ids)
    push!(columns,(;q,d,t,path=copy(path),coefficients=sparsevec(loads),segments=[i+(j-1)*n for (i,j) in pairs]))
    push!(keys[q],key)
    return length(columns)
end

# ╔═╡ 58534b35-038a-4589-8911-c9266655d42c
md"""
### `expand_time01_columns!` — enumerate further valid columns with a persistent cursor

Visits waypoint sequences in increasing length, including vertex revisits, without storing an exponential search tree. A completed cursor establishes that the whole route domain was enumerated. The small official example is enumerated completely; large instances receive bounded batches and remain uncertified unless a global bound closes.
"""

# ╔═╡ e72379af-2de9-4b3b-bcc1-35b1cbaf32ee
function expand_time01_columns!(columns,keys,data,ranks,hops;max_routes=typemax(Int),
        per_group=2,deadline=Inf,max_columns=100_000)
    n=length(data.node_ids);D=length(data.sources);added=0
    for q in eachindex(keys)
        accepted=0;attempts=0;d=mod(q-1,D)+1;t=div(q-1,D)
        while hops[q]<data.MaxSeg && accepted<per_group && attempts<100_000
            time()>=deadline && return (;added,complete=false)
            length(columns)>=max_columns && return (;added,complete=false)
            length(keys[q])>=max_routes && break
            count=big(n)^hops[q]
            if ranks[q]>=count
                ranks[q]=0;hops[q]+=1;continue
            end
            rank=ranks[q];ranks[q]+=1;attempts+=1
            path=Int[data.sources[d]]
            for h in 1:hops[q]
                push!(path,Int(mod(rank,n))+1);rank=div(rank,n)
            end
            push!(path,data.targets[d]);pairs=collect(zip(path,path[2:end]))
            all(i!=j && data.periods[t+1].counts[i,j]>0 for (i,j) in pairs) || continue
            length(unique(pairs))==length(pairs) || continue
            p=add_time01_column!(columns,keys,data,q,path;max_routes)
            p>0 && (accepted+=1;added+=1)
        end
    end
    return (;added,complete=all(hops.>=data.MaxSeg))
end

# ╔═╡ 7003ce69-5a05-4db5-b8ca-a71b15ab0061
md"""
### `build_time01_master` — select routes with the original cross-period Budget

Builds a fresh LP or binary master. Demand/period equalities select one route; physical rows recompute both-period loads. Sparse change variables and two absolute-value inequalities per used demand/segment enforce Budget. Previously certified global top-k locks are retained. No demand-by-all-segments tensor is allocated.
"""

# ╔═╡ c86c4c6c-6816-4b47-abe1-9d4f53ee102f
function build_time01_master(data,columns,k,locks;integer=true,solver=:highs,
        time_limit=60.,seed=1,threads=1,max_variables=2_000_000)
    D=length(data.sources);m=length(data.arcs)
    pair_keys=sort(unique([(c.d,s) for c in columns for s in c.segments]))
    length(columns)+length(pair_keys)+2m*(length(locks)+2)<=max_variables || error("MODEL_SIZE_LIMIT: temporal master allocation guard")
    model=create_time0_optimizer(integer ? solver : :highs;time_limit,seed,threads=integer ? threads : 1)
    set_string_names_on_creation(model,false)
    y=@variable(model,[1:length(columns)],lower_bound=0.)
    integer && foreach(set_binary,y)
    loads=@variable(model,[1:2m],lower_bound=0.)
    z=@variable(model,lower_bound=0.)
    bygroup=[Int[] for q in 1:2D]
    for (p,c) in enumerate(columns)
        push!(bygroup[c.q],p)
    end
    convexity=[@constraint(model,sum(y[p] for p in bygroup[q])==1) for q in 1:2D]
    expressions=[AffExpr(0.) for a in 1:2m]
    changes=Dict(key=>AffExpr(0.) for key in pair_keys)
    for (p,c) in enumerate(columns)
        indices,values=findnz(c.coefficients)
        for h in eachindex(indices)
            add_to_expression!(expressions[c.t*m+indices[h]],values[h],y[p])
        end
        for s in c.segments
            add_to_expression!(changes[c.d,s],c.t==1 ? 1. : -1.,y[p])
        end
    end
    load_rows=[@constraint(model,expressions[a]<=loads[a]) for a in 1:2m]
    for a in 1:2m
        @constraint(model,loads[a]<=z)
    end
    h=@variable(model,[1:length(pair_keys)],lower_bound=0.,upper_bound=1.)
    plus=[@constraint(model,changes[key]<=h[i]) for (i,key) in enumerate(pair_keys)]
    minus=[@constraint(model,-changes[key]<=h[i]) for (i,key) in enumerate(pair_keys)]
    budget_row=@constraint(model,sum(h)<=data.budget)
    master=(;model,y,loads,z,convexity,load_rows,plus,minus,pair_keys,h,budget_row,bygroup)
    for j in eachindex(locks)
        previous=add_lexicographic_stage!(master,j,2m)
        @constraint(model,previous.expression<=locks[j])
    end
    stage=add_lexicographic_stage!(master,k,2m)
    return merge(master,(;stage))
end

# ╔═╡ 728107f3-38e8-49eb-82cd-ac3556a23c02
md"""
### `validate_time01_selection` — independently check routes, loads and Budget

Recomputes each physical load directly from r, reconstructs original-ID waypoint output for both periods and computes the actual symmetric-difference transition cost. Saved pool coefficients and solver change-variable values are not trusted. A feasible incumbent must satisfy the original Budget exactly as an integer count.
"""

# ╔═╡ 266dfd3f-b287-49d7-9a3a-65892b36c770
function validate_time01_selection(data,columns,selection)
    D=length(data.sources);m=length(data.arcs)
    length(selection)==2D || error("Missing temporal routes")
    loads=zeros(2m);paths=Vector{Int}[];srpaths=NamedTuple[]
    for q in 1:2D
        c=columns[selection[q]];c.q==q || error("Wrong demand/period selection")
        path=c.path;pairs=collect(zip(path,path[2:end]))
        first(path)==data.sources[c.d] && last(path)==data.targets[c.d] || error("Invalid temporal endpoints")
        length(pairs)<=data.MaxSeg && length(unique(pairs))==length(pairs) || error("Invalid temporal segments")
        for (i,j) in pairs
            i!=j && data.periods[c.t+1].counts[i,j]>0 || error("Unreachable temporal segment")
            for a in eachindex(data.arcs)
                loads[c.t*m+a]+=data.v[c.d,c.t]*data.r[i,j,a,c.t]/data.c[a]
            end
        end
        push!(paths,copy(path))
        push!(srpaths,(d=data.demand_ids[c.d],t=c.t,w=data.node_ids[path[2:end-1]]))
    end
    cost=sum(segment_change_count(paths[d],paths[D+d]) for d in 1:D)
    cost<=data.budget || error("Temporal Budget violated: $cost > $(data.budget)")
    return (;valid=true,loads,paths,srpaths,cost,selection=copy(selection),mlu=maximum(loads;init=0.))
end

# ╔═╡ 824855af-6248-4b15-9578-ba9b06881abe
md"""
### `start_time01_master!` — submit a validated feasible warm start

Sets selected route binaries, exact physical loads and MLU. Epigraph starts may be completed by the solver. Change-variable starts equal the selected segment-set differences. Each master is fresh, avoiding repeated partial-start accumulation in incremental SCIP solves.
"""

# ╔═╡ 1958d2c4-f17f-4dfc-8905-a4ea32570430
function start_time01_master!(master,columns,validation,data,k,locks)
    for p in eachindex(master.y)
        set_start_value(master.y[p],p in validation.selection ? 1. : 0.)
    end
    for a in eachindex(master.loads)
        set_start_value(master.loads[a],validation.loads[a])
    end
    set_start_value(master.z,validation.mlu)
    for (i,(d,s)) in enumerate(master.pair_keys)
        present0=s in columns[validation.selection[d]].segments
        present1=s in columns[validation.selection[length(data.sources)+d]].segments
        set_start_value(master.h[i],present0!=present1 ? 1. : 0.)
    end
    # Fresh epigraph variables need not have explicit starts; the solver may complete them.
    return nothing
end

# ╔═╡ 77eb45a4-a033-4906-afac-c5eedf0618bf
md"""
### `temporal_pricing_bound` — certify a global LP bound, not a pool bound

Uses the restricted LP's demand/period and physical-load duals. Signed dual prices from the absolute-value Budget rows contribute to segment costs. Hop-bounded dynamic programming prices a relaxation allowing repeated ordered segments; its minimum is no larger than the minimum over valid binary-segment columns, so it yields a conservative missing-column correction even if its minimizing walk is inadmissible. Only a full completed sweep supplies a bound. A valid priced sequence can be added to the pool; an invalid walk is never installed as a route.

```math
\rho_{dt}^{LB}\le\min_{p\in P_{dt}}(c_{dtp}^{dual}-\alpha_{dt}),\qquad
LB=D_R+\sum_{d,t}\min(0,\rho_{dt}^{LB}).
```

Missing Budget incidence rows are extended with zero duals; their new change variables have nonnegative reduced cost under the nonpositive Budget dual. A numerical safety buffer is subtracted. If interrupted before every demand/period has been priced, this function returns no new global bound.
"""

# ╔═╡ 8c2c269f-ae46-4281-a5de-7aacde226a8e
function temporal_pricing_bound(data,master;deadline=Inf)
    D=length(data.sources);n=length(data.node_ids);m=length(data.arcs)
    alpha=dual.(master.convexity);weights=-dual.(master.load_rows)
    minimum(weights;init=0.)>=-1e-7 || error("Invalid temporal load dual")
    plus=dual.(master.plus);minus=dual.(master.minus)
    projection_error=sum(sum(data.v[d,t] for d in 1:D)*data.MaxSeg*sum(max.(-weights[t*m+1:(t+1)*m],0.)./data.c) for t in 0:1)
    weights=max.(weights,0.)
    physical=[reshape(data.periods[t+1].r.values*(weights[t*m+1:(t+1)*m]./data.c),n,n) for t in 0:1]
    correction=0.;priced=NamedTuple[]
    budget_rows_by_demand=[Int[] for d in 1:D]
    for (h,(d,s)) in enumerate(master.pair_keys)
        push!(budget_rows_by_demand[d],h)
    end
    for q in 1:2D
        time()>=deadline && return (;complete=false,bound=missing,priced)
        d=mod(q-1,D)+1;t=div(q-1,D)
        costs=data.v[d,t].*physical[t+1]
        for h in budget_rows_by_demand[d]
            demand,s=master.pair_keys[h]
            i=mod(s-1,n)+1;j=div(s-1,n)+1
            costs[i,j]+=(t==0 ? 1. : -1.)*(plus[h]-minus[h])
        end
        for j in 1:n,i in 1:n
            (i==j || data.periods[t+1].counts[i,j]==0) && (costs[i,j]=Inf)
        end
        previous=fill(Inf,n);previous[data.targets[d]]=0.
        successors=zeros(Int,n,data.MaxSeg)
        for hop in 1:data.MaxSeg
            current=copy(previous)
            for j in 1:n,i in 1:n
                candidate=costs[i,j]+previous[j]
                if candidate<current[i]
                    current[i]=candidate;successors[i,hop]=j
                end
            end
            previous=current
        end
        rho=previous[data.sources[d]]-alpha[q];correction+=min(0.,rho)
        path=Int[data.sources[d]];node=data.sources[d]
        for hop in data.MaxSeg:-1:1
            next=successors[node,hop]
            next==0 && continue
            push!(path,next);node=next
        end
        pairs=collect(zip(path,path[2:end]))
        if rho < -1e-8 && last(path)==data.targets[d] && length(unique(pairs))==length(pairs)
            push!(priced,(;q,path))
        end
    end
    dual_value=dual_objective_value(master.model)
    safety=1e-7*(1+abs(dual_value)+sum(abs,alpha)+sum(abs,weights)+sum(abs,plus)+sum(abs,minus))
    # Compensate for clamping tiny negative load duals before pricing.
    bound=max(0.,dual_value+correction-safety-projection_error)
    return (;complete=true,bound,priced)
end

# ╔═╡ 73bd06cb-46f4-4575-bf95-df966b1249dc
md"""
### `solve_time01_separate` — reference formulation with separate period columns

Defaults to HiGHS and rebuilds a sparse route master for each stage/cycle. Small official fixtures enumerate their full connected, no-repeated-segment domain; larger instances use bounded enumeration and valid priced columns. The first LP gives a corrected global bound; native MIP bounds are global only for a complete pool. Only a globally certified stage is locked. A positive gap keeps the current stage active while budget and wall safeguards permit expansion. The 10% reporting target never relaxes Budget, constraints or lexicographic locks. The allocation guard can reject an oversized selected master; this is not a proof of infeasibility.
"""

# ╔═╡ 24e03d85-549e-4048-a07b-c76c927c239f
function solve_time01_separate(data;time_limit=3600.,solver=:highs,seed=1,threads=1,
        target_gap=.10,lock_tolerance=1e-7,proof_tolerance=2e-6,max_variables=2_000_000,
        max_columns=100_000,log_file="",solution_file="")
    isfinite(time_limit)&&time_limit>0 || error("Invalid two-period time limit")
    data.budget>=0 || error("Invalid Budget")
    isempty(solution_file) || mkpath(dirname(abspath(solution_file)))
    isempty(log_file) || mkpath(dirname(abspath(log_file)))
    lock(ORANGE_SOLVER_LOCK)
    try
        solver==:highs && HiGHS.Highs_resetGlobalScheduler(1)
        started=time();elapsed=0.;D=length(data.sources);m=length(data.arcs)
        columns=NamedTuple[];keys=[Set{Tuple}() for q in 1:2D]
        for q in 1:2D
            d=mod(q-1,D)+1
            add_time01_column!(columns,keys,data,q,[data.sources[d],data.targets[d]])
        end
        selection=collect(1:2D);validation=validate_time01_selection(data,columns,selection)
        ranks=fill(big(0),2D);hops=zeros(Int,2D)
        tiny=length(data.node_ids)<=8 && data.MaxSeg<=4
        complete=false;pool_limit=16;locks=Float64[];completed=0;k=1;cycle=0
        first_bound=0.;active_bound=0.;stage_bound=0.;status="Not Optimal";termination="TIME_LIMIT";nodes=0
        !isempty(log_file) && isfile(log_file) && rm(log_file)
        while k<=2m
            remaining=time_limit-elapsed
            remaining<=1e-3 && break
            time()-started>time_limit+max(30.,.1*time_limit) && (termination="SEARCH_WALL_LIMIT";break)
            cycle+=1
            expansion=expand_time01_columns!(columns,keys,data,ranks,hops;
                per_group=tiny ? typemax(Int) : 2,max_routes=tiny ? typemax(Int) : pool_limit,
                deadline=time()+min(5.,max(.1,remaining)),max_columns)
            complete=expansion.complete
            lp=build_time01_master(data,columns,k,locks;integer=false,time_limit=min(remaining*.25,30.),seed,max_variables)
            install_highs_deadline!(lp.model,min(remaining*.25,30.))
            seconds=@elapsed optimize!(lp.model);elapsed+=seconds
            price=(complete=false,bound=missing,priced=NamedTuple[])
            if termination_status(lp.model)==ORANGE_MOI.OPTIMAL && dual_status(lp.model)==ORANGE_MOI.FEASIBLE_POINT
                price=temporal_pricing_bound(data,lp;deadline=time()+min(5.,max(.1,time_limit-elapsed)))
            end
            empty!(lp.model)
            active_bound=max(stage_bound,ismissing(price.bound) ? 0. : price.bound)
            k==1 && (first_bound=max(first_bound,active_bound))
            for candidate in price.priced
                length(columns)>=max_columns && break
                add_time01_column!(columns,keys,data,candidate.q,candidate.path;max_routes=pool_limit)
            end
            remaining=time_limit-elapsed
            value_now=sum(sort(validation.loads;rev=true)[1:k]);native_bound=missing
            mip_seconds=0.;native_status="NOT_RUN"
            if remaining>1e-3 && value_now-active_bound>proof_tolerance
                slice=min(60.,remaining)
                master=build_time01_master(data,columns,k,locks;solver,time_limit=slice,seed,threads,max_variables)
                start_time01_master!(master,columns,validation,data,k,locks)
                solver==:highs && install_highs_deadline!(master.model,slice)
                mip_seconds=@elapsed optimize!(master.model);elapsed+=mip_seconds
                native_status=string(termination_status(master.model))
                nodes+=node_count(master.model)
                bound=objective_bound(master.model)
                isfinite(bound) && (native_bound=bound)
                complete && !ismissing(native_bound) && (active_bound=max(active_bound,native_bound))
                if primal_status(master.model)==ORANGE_MOI.FEASIBLE_POINT
                    chosen=[only([p for p in master.bygroup[q] if value(master.y[p])>.5]) for q in 1:2D]
                    all(abs(value(y)-round(value(y)))<1e-5 for y in master.y) || error("Noninteger temporal selection")
                    candidate=validate_time01_selection(data,columns,chosen)
                    vector=sort(candidate.loads;rev=true)
                    all(sum(vector[1:j])<=locks[j]+1e-5 for j in eachindex(locks)) || error("Earlier temporal lock violated")
                    if sum(vector[1:k])<=value_now+1e-7
                        validation=candidate;value_now=sum(vector[1:k])
                    end
                end
                empty!(master.model)
            end
            active_bound<=value_now+proof_tolerance || error("Temporal lower bound exceeds incumbent")
            k==1 && (first_bound=max(first_bound,active_bound))
            certified=value_now-active_bound<=proof_tolerance
            row=(stage=k,cycle,objective=value_now,global_bound=active_bound,gap=experiment_gap(value_now,active_bound),
                globally_certified=certified,pool_complete=complete,columns=length(columns),budget_used=validation.cost,
                lp_seconds=seconds,mip_seconds,cumulative_optimize_seconds=elapsed,native_status,restricted_bound=native_bound)
            isempty(log_file) || append_result_csv(log_file,row)
            if certified
                completed=k;push!(locks,value_now+lock_tolerance);k+=1;cycle=0;stage_bound=0.
            else
                stage_bound=active_bound;pool_limit=min(max_columns,2*pool_limit)
                length(columns)>=max_columns && (termination="ROUTE_POOL_LIMIT";break)
            end
            if !isempty(solution_file)
                payload=(srpaths=validation.srpaths,validated=true,budget_used=validation.cost,budget=data.budget,
                    mlu=validation.mlu,global_mlu_bound=first_bound,lex_completed_stages=completed,
                    lex_total_stages=2m,termination="RUNNING",sorted_loads=sort(validation.loads;rev=true))
                write(solution_file*".tmp",JSON3.write(payload));mv(solution_file*".tmp",solution_file;force=true)
            end
        end
        completed==2m && (status="Optimal";termination="OPTIMAL")
        gap=experiment_gap(validation.mlu,first_bound)
        result=(status,termination,objective=validation.mlu,lower_bound=first_bound,gap,
            validated=true,budget_used=validation.cost,budget=data.budget,lex_completed_stages=completed,
            lex_total_stages=2m,active_stage=min(k,2m),stage_lower_bound=active_bound,
            stage_objective=sum(sort(validation.loads;rev=true)[1:min(k,2m)]),cpu_time_seconds=elapsed,
            wall_time_seconds=time()-started,columns=length(columns),pool_complete=complete,nodes,
            mlu_target_met=!ismissing(gap)&&gap<=target_gap,sorted_loads=sort(validation.loads;rev=true),srpaths=validation.srpaths,
            solver=String(solver),solver_version=orange_solver_version(solver),objective_mode="lexicographic_all_arcs_all_periods",
            lock_tolerance,proof_tolerance,log_file,solution_file)
        if !isempty(solution_file)
            write(solution_file*".tmp",JSON3.write(result));mv(solution_file*".tmp",solution_file;force=true)
        end
        return result
    finally
        unlock(ORANGE_SOLVER_LOCK)
    end
end

# ╔═╡ 12515315-5f71-4eb4-b405-5ca901ebffcb
md"""
## Worked Data and solve: the official Orange example

The next cells show both graphs, failed IDs, traffic, recomputed r and Budget. The solve is a short correctness demonstration, not a SetA benchmark or Step 9 batch. Its objective combines all 44 physical arc/time entries.
"""

# ╔═╡ a1f95b24-c1c5-478c-936a-63b90b602562
orange_time01_demo_data=load_time01_data(joinpath(@__DIR__,"test","fixtures","orange_subject_toy","toy"))

# ╔═╡ ca0e6c98-d6ee-47a4-b9b6-dbe3caabb914
(
    vertices=length(orange_time01_demo_data.node_ids),
    links_time0=ne(orange_time01_demo_data.graphs[1]),links_time1=ne(orange_time01_demo_data.graphs[2]),
    failed_link_ids=orange_time01_demo_data.periods[2].failed_arc_ids,
    time_axis=axes(orange_time01_demo_data.r,4),traffic=orange_time01_demo_data.v,
    budget=orange_time01_demo_data.budget,
    r_0_to_5_on_arc_0=([orange_time01_demo_data.r[1,6,1,t] for t in 0:1]),
    direct_to_waypoint_budget=segment_change_count([1,6],[1,5,6]),
)

# ╔═╡ 447f38c1-525b-46e8-ac64-d13624aad031
orange_time01_demo_result=solve_time01_separate(orange_time01_demo_data;time_limit=5.)

# ╔═╡ 35b21d5d-99f6-443f-87f4-2a4a16c8a081
(
    status=orange_time01_demo_result.status,termination=orange_time01_demo_result.termination,
    sorted_loads=orange_time01_demo_result.sorted_loads,
    certified_stages=orange_time01_demo_result.lex_completed_stages,
    total_stages=orange_time01_demo_result.lex_total_stages,
    budget_used=orange_time01_demo_result.budget_used,budget=orange_time01_demo_result.budget,
    mlu=orange_time01_demo_result.objective,optimize_seconds=orange_time01_demo_result.cpu_time_seconds,
)

# ╔═╡ a8210754-6806-4466-a97f-c27323f6ac3d
md"""
# Demand decomposition: paired-route master and pricing

Each column q=(p0,p1) belongs to one demand d and contains a valid segment sequence in each period. Its coefficients are calculated from the original Data, not new routing assumptions:

```math
\ell_{dq,a,t}=\frac{v_{d,t}}{c_a}\sum_{(i,j)\in S(p_t)}r[i,j,a,t],\qquad
b_{dq}=|S(p_0)\triangle S(p_1)|.
```

The complete integer master is equivalent to selecting one original route per demand/period with the original Budget:

```math
\sum_{q\in Q_d}y_{dq}=1,\quad y_{dq}\in\{0,1\},\qquad
\sum_{d,q}b_{dq}y_{dq}\le\kappa_1,\qquad
\sum_{d,q}\ell_{dq,a,t}y_{dq}\le\lambda_{a,t}.
```

Unlike separate-period incidence relaxation, the LP pays the expected actual change of each route pair. Jensen's inequality gives |E[x1]-E[x0]| <= E[|x1-x0|]; hence paired columns can tighten the Budget relaxation. The restricted pool still needs pricing. No original capacity, traffic, MaxSeg, ECMP or Budget value is changed.

At stage k, the master minimizes the same top-k function F_k of the joint sorted arc/time vector, retaining all earlier globally certified locks. Pricing reads the physical-load duals w, Budget price mu, and demand equality dual alpha:

```math
\bar c_d(q)=\sum_{a,t}w_{a,t}\ell_{dq,a,t}+\mu b_{dq}-\alpha_d.
```

The minimization is over a pair for one demand; other demands do not appear. Independent demand pricing can be parallelized mathematically, but this implementation deliberately runs it serially on local CPU with one shared optimize-call budget.

For the MLU stage, the Lagrangian interpretation is

```math
\max_{w\ge0,\ \sum_{a,t}w_{a,t}=1,\ \mu\ge0}
\left[\sum_d\min_{q\in Q_d}\left(\sum_{a,t}w_{a,t}\ell_{dq,a,t}+\mu b_{dq}\right)-\mu\kappa_1\right].
```

Later stages use the duals of their actual top-k master, including earlier locks; the normalized MLU formula alone must not be reused for those stages.

References: [Dantzig and Wolfe (1960)](https://doi.org/10.1287/opre.8.1.101), [CG4SR, Jadin et al. (2019)](https://inlold.info.ucl.ac.be/system/files/cg4sr.pdf), and [Barnhart et al. (1998)](https://doi.org/10.1287/opre.46.3.316). This is root column generation plus restricted integer masters, not branch-and-price.
"""

# ╔═╡ bfa1a8c7-e37e-4959-ad89-d12eed9a827b
md"""
### `time01_pair_route` and `add_time01_pair!` — store one demand's two routes

The first function validates one sequence and computes its physical coefficients. The second stores a unique pair, its sparse 2|A| load vector and exact segment-set change. A pair costing more than the entire Budget is excluded safely because all other demand costs are nonnegative. Vertex revisits remain allowed; repeated ordered segments remain forbidden by binary segment incidence.
"""

# ╔═╡ 89e8fe74-8770-4a9f-a26c-abe0f33a940f
function time01_pair_route(data,d,t,path)
    n=length(data.node_ids)
    length(path)>=2 && all(i->1<=i<=n,path) || error("Invalid pair route vertices")
    first(path)==data.sources[d] && last(path)==data.targets[d] || error("Wrong pair endpoints")
    pairs=collect(zip(path,path[2:end]))
    length(pairs)<=data.MaxSeg && length(unique(pairs))==length(pairs) || error("Invalid pair segment count/incidence")
    all(i!=j && data.periods[t+1].counts[i,j]>0 for (i,j) in pairs) || error("Unreachable pair segment")
    coefficients=zeros(length(data.arcs))
    if hasproperty(data,:pair_ratios)
        ratios=data.pair_ratios[t+1];rows=rowvals(ratios);values=nonzeros(ratios)
        for (i,j) in pairs,entry in nzrange(ratios,i+(j-1)*n)
            a=rows[entry];coefficients[a]+=data.v[d,t]*values[entry]/data.c[a]
        end
    else
        for (i,j) in pairs,a in eachindex(coefficients)
            coefficients[a]+=data.v[d,t]*data.r[i,j,a,t]/data.c[a]
        end
    end
    return (;q=t*length(data.sources)+d,d,t,path=collect(Int,path),coefficients=sparsevec(coefficients),
        segments=[i+(j-1)*n for (i,j) in pairs])
end

# ╔═╡ 86d52d2f-1256-46d9-8b22-0ac58e705fd3
function add_time01_pair!(columns,keys,data,d,path0,path1;max_columns=100_000)
    key=(Tuple(path0),Tuple(path1))
    key in keys[d] && return 0
    length(columns)>=max_columns && return 0
    c0=time01_pair_route(data,d,0,path0);c1=time01_pair_route(data,d,1,path1)
    cost=segment_change_count(path0,path1)
    cost>data.budget && return 0
    push!(columns,(;d,paths=(c0.path,c1.path),period_columns=(c0,c1),
        coefficients=vcat(c0.coefficients,c1.coefficients),cost))
    push!(keys[d],key)
    return length(columns)
end

# ╔═╡ ecd1fc1a-8f22-47a7-bd14-f42ac885c3d2
md"""
### `build_time01_pair_master` — coordinate demand columns

Creates an LP for pricing or a binary master for feasible solutions. One equality per demand replaces separate period equalities; the single Budget row uses precomputed actual change costs. Physical rows and existing top-k epigraphs/locks retain the original objective. A variable-count guard rejects excessive allocations before construction.
"""

# ╔═╡ ecb40588-559b-45c1-a321-c17fa002f441
function build_time01_pair_master(data,columns,k,locks;integer=false,solver=:highs,
        time_limit=10.,seed=1,threads=1,max_variables=2_000_000)
    D=length(data.sources);M=2length(data.arcs)
    length(columns)+M*(length(locks)+2)+1<=max_variables || error("MODEL_SIZE_LIMIT: pair master")
    model=create_time0_optimizer(integer ? solver : :highs;time_limit,seed,threads=integer ? threads : 1)
    set_string_names_on_creation(model,false)
    y=@variable(model,[1:length(columns)],lower_bound=0.)
    integer && foreach(set_binary,y)
    loads=@variable(model,[1:M],lower_bound=0.)
    z=@variable(model,lower_bound=0.)
    bygroup=[Int[] for d in 1:D];expressions=[AffExpr(0.) for a in 1:M]
    for (p,c) in enumerate(columns)
        push!(bygroup[c.d],p)
        indices,coefficients=findnz(c.coefficients)
        for h in eachindex(indices)
            add_to_expression!(expressions[indices[h]],coefficients[h],y[p])
        end
    end
    convexity=[@constraint(model,sum(y[p] for p in bygroup[d])==1) for d in 1:D]
    load_rows=[@constraint(model,expressions[a]<=loads[a]) for a in 1:M]
    @constraint(model,[a in 1:M],loads[a]<=z)
    budget_row=@constraint(model,sum(c.cost*y[p] for (p,c) in enumerate(columns))<=data.budget)
    master=(;model,y,loads,z,convexity,load_rows,budget_row,bygroup)
    for j in eachindex(locks)
        previous=add_lexicographic_stage!(master,j,M)
        @constraint(model,previous.expression<=locks[j])
    end
    stage=add_lexicographic_stage!(master,k,M)
    return merge(master,(;stage))
end

# ╔═╡ 078626be-dbe4-46d9-85cc-b3746fdab7bc
md"""
### `build_time01_pair_pricer` — one exact, hop-indexed demand subproblem

Binary u[t,h,e] selects a segment transition at layer h. Layer flow carries one unit from the source at layer 0 to the target at layer K. A target-to-itself waiting transition pads shorter routes; it has zero cost, is removed when exporting and is not counted as a segment. Real ordered segments can occur at most once, while revisited vertices are retained.

```math
x_{ij,t}=\sum_{h=1}^{K}u_{t,h,(i,j)}\le1,\qquad
h_{ij}\ge\pm(x_{ij,1}-x_{ij,0}),\qquad
h_{ij}\le x_{ij,0}+x_{ij,1},\quad
h_{ij}\le2-x_{ij,0}-x_{ij,1}.
```

The last two inequalities make h the exact XOR even for tiny signed numerical duals. The objective is sum(w*ell)+mu*sum(h); alpha is subtracted afterwards. The per-demand restriction sum(h)<=Budget safely removes globally impossible pairs. No global Budget is allocated permanently to a particular demand. Existing-pair exclusion cuts are used only for diversification, never for claiming the unrestricted pricing bound. Excessive pricing size is guarded explicitly.
"""

# ╔═╡ 5ad94785-6cdf-47df-aa5c-32f620439eae
function build_time01_pair_pricer(data,d,physical,mu;solver=:highs,time_limit=1.,seed=1,threads=1,
        max_variables=200_000,exclude_pairs=NamedTuple[])
    n=length(data.node_ids);K=data.MaxSeg;s=data.sources[d];target=data.targets[d]
    edges=[vcat(collect(data.periods[t+1].segments),[(target,target)]) for t in 0:1]
    union_edges=sort(unique(vcat(edges[1][1:end-1],edges[2][1:end-1])))
    K*sum(length,edges)+length(union_edges)<=max_variables || error("MODEL_SIZE_LIMIT: demand pair pricing")
    model=create_time0_optimizer(solver;time_limit,seed,threads)
    set_string_names_on_creation(model,false)
    u=[@variable(model,[1:K,1:length(edges[t])],binary=true) for t in 1:2]
    incidence=[Dict{Tuple{Int,Int},AffExpr}() for t in 1:2]
    for t in 1:2
        outgoing=[Int[] for i in 1:n];incoming=[Int[] for i in 1:n]
        for (e,(i,j)) in enumerate(edges[t])
            push!(outgoing[i],e);push!(incoming[j],e)
            i==j && continue
            expression=sum(u[t][h,e] for h in 1:K)
            incidence[t][i,j]=expression
            @constraint(model,expression<=1)
        end
        for h in 1:K,i in 1:n
            rhs=h==1 ? AffExpr(i==s ? 1. : 0.) : sum(u[t][h-1,e] for e in incoming[i])
            @constraint(model,sum(u[t][h,e] for e in outgoing[i])==rhs)
        end
        for i in 1:n
            @constraint(model,sum(u[t][K,e] for e in incoming[i])==(i==target ? 1. : 0.))
        end
    end
    h=@variable(model,[1:length(union_edges)],lower_bound=0.,upper_bound=1.)
    for (a,edge) in enumerate(union_edges)
        x0=get(incidence[1],edge,AffExpr(0.));x1=get(incidence[2],edge,AffExpr(0.))
        @constraint(model,h[a]>=x1-x0);@constraint(model,h[a]>=x0-x1)
        @constraint(model,h[a]<=x0+x1);@constraint(model,h[a]<=2-x0-x1)
    end
    @constraint(model,sum(h)<=data.budget)
    for c in exclude_pairs
        difference=AffExpr(0.)
        for t in 1:2,edge in union_edges
            expression=get(incidence[t],edge,AffExpr(0.))
            present=edge in Set(zip(c.paths[t],c.paths[t][2:end]))
            difference+=present ? 1-expression : expression
        end
        @constraint(model,difference>=1)
    end
    objective=AffExpr(0.)
    for t in 1:2,(e,(i,j)) in enumerate(edges[t]),hop in 1:K
        i==j && continue
        add_to_expression!(objective,data.v[d,t-1]*physical[t][i,j],u[t][hop,e])
    end
    for a in eachindex(h)
        add_to_expression!(objective,mu,h[a])
    end
    @objective(model,Min,objective)
    return (;model,u,edges,h,incidence,union_edges,d)
end

# ╔═╡ 1e8b54ae-325c-4e54-a2cc-057ee34c0ac9
md"""
### `price_time01_demand` — solve, reconstruct and bound one route pair

Every optimize call, including pricing MIPs, counts toward the shared budget. A feasible pricing incumbent generates a validated pair, but is an upper bound on the pricing minimum. Only a solver lower bound (or the conservative analytical floor) is used for the master correction. A time limit never turns a heuristic price into an exact pricing certificate. The native log is optional; all model instances are released after use.
"""

# ╔═╡ 2fdaf07d-a848-4cb3-ba89-b73e572c1e82
function price_time01_demand(data,d,physical,mu;time_limit=1.,solver=:highs,seed=1,threads=1,
        max_variables=200_000,exclude_pairs=NamedTuple[],log_file="")
    pricer=build_time01_pair_pricer(data,d,physical,mu;time_limit,solver,seed,threads,max_variables,exclude_pairs)
    try
        set_stage_log!(pricer.model,solver,log_file)
        solver==:highs && install_highs_deadline!(pricer.model,time_limit)
        seconds=@elapsed optimize!(pricer.model)
        status=termination_status(pricer.model)
        bound=objective_bound(pricer.model)
        lower_bound=isfinite(bound)&&abs(bound)<1e19 ? bound : missing
        candidate=nothing
        if primal_status(pricer.model)==ORANGE_MOI.FEASIBLE_POINT
            paths=Vector{Int}[]
            for t in 1:2
                path=Int[data.sources[d]]
                for hop in 1:data.MaxSeg
                    selected=[e for e in eachindex(pricer.edges[t]) if value(pricer.u[t][hop,e])>.5]
                    length(selected)==1 || error("Nonintegral pair pricing layer")
                    i,j=pricer.edges[t][only(selected)]
                    last(path)==i || error("Disconnected pair pricing path")
                    i==j || push!(path,j)
                end
                time01_pair_route(data,d,t-1,path)
                push!(paths,path)
            end
            cost=segment_change_count(paths[1],paths[2])
            cost<=data.budget || error("Pair pricing violates Budget")
            actual=sum(data.v[d,t-1]*physical[t][i,j] for t in 1:2 for (i,j) in zip(paths[t],paths[t][2:end]))+mu*cost
            abs(actual-objective_value(pricer.model))<=1e-5*(1+abs(actual)) || error("Pricing objective reconstruction mismatch")
            candidate=(;d,path0=paths[1],path1=paths[2],cost,objective=actual)
        end
        return (;d,seconds,status=string(status),lower_bound,candidate,nodes=node_count(pricer.model))
    finally
        close_stage_log!(pricer.model,solver)
        empty!(pricer.model)
    end
end

# ╔═╡ 23f76f06-9035-477c-9478-69808a03c56c
md"""
### `time01_pair_duals` and `time01_pair_bound` — retain a full-domain lower bound

The missing-column correction uses the lower bound l_d on each pricing minimum:

```math
LB=D_R+\sum_d\min(0,l_d-\alpha_d).
```

Before pricing, a safe floor is K times the most negative segment cost in each period plus min(0,2K*mu). It relaxes connectivity and Budget and is therefore a lower bound even for unvisited demands. A completed pricing solve tightens that floor. Consequently a partial sweep can still supply a conservative global bound. Signed tiny load duals are priced directly, without an uncompensated projection. A numerical safety buffer is subtracted. This bound applies only to this LP stage and its inherited locks, not to an unrelated lexicographic stage.
"""

# ╔═╡ 6182b0cb-c9dd-4d99-b81f-a83b853fa6a3
md"""
### Fast pair pricing: shared dynamic programs and a valid Budget bound

The large-instance default avoids building millions of hop-indexed binaries for every demand. `time01_hop_prices` computes a hop-bounded minimum walk for all sources sharing a destination. Repeated segment walks form a relaxation for the bound; only routes with no repeated ordered segments enter the master. All original MILP constraints and the exact pricing routine remain available.

Let ``a_d`` be the sum of independent period minimum walk costs, and ``b_d`` a lower bound for the cheapest common route under both periods' physical dual costs. If two binary segment sets differ while retaining the same flow balance, their symmetric difference contains at least two arcs (a two-edge cycle is permitted). Consequently, for nonnegative Budget dual ``\mu``,

```math
\min_q c_d(q)\ \ge\ \min\{b_d,a_d+2\mu\}.
```

When Budget is less than two, only identical sets are possible and ``b_d`` alone is valid. Tiny negative duals use the conservative ``2K\mu`` floor instead. None of these bounds treats a restricted-pool MIP bound as global.

For a common route define ``f_d(\rho)=\min_p\sum_{(i,j)\in p}[\rho P^0_{ij}+(1-\rho)P^1_{ij}]``. This is concave as a minimum of affine functions. Linear interpolation of exact walk minima on ``\rho\in\{0,1/4,1/2,3/4,1\}`` is therefore a lower bound, with ``\rho=v_{d0}/(v_{d0}+v_{d1})`` and scale ``v_{d0}+v_{d1}``. Signed costs and relaxed walks preserve the lower-bound direction. Valid grid paths and independent paths supply candidate columns; every chosen incumbent is revalidated against the original Budget and physical loads. A full sweep is required before installing the bound.

Dynamic-program time is recorded as pricing wall time, **not** as `optimize!` time. MLU gap at most 10% remains a reporting target: search continues, and later lexicographic stages are entered only after a global certificate.
"""

# ╔═╡ 1e6d2f6f-ba1d-43f7-93b4-702a437e8936
function time01_hop_prices(data,costs;deadline=Inf,period=nothing)
    n=length(data.node_ids);D=length(data.sources);K=data.MaxSeg
    matrix=copy(costs)
    for j in 1:n,i in 1:n
        available=period===nothing ? all(p.counts[i,j]>0 for p in data.periods) : data.periods[period+1].counts[i,j]>0
        (i==j || !available) && (matrix[i,j]=Inf)
    end
    lower=fill(-Inf,D);paths=[Int[] for _ in 1:D]
    for target in sort(unique(data.targets))
        previous=fill(Inf,n);previous[target]=0.;successors=zeros(Int,n,K)
        for hop in 1:K
            time()>deadline && return (;complete=false,lower,paths)
            current=copy(previous)
            for j in 1:n
                isfinite(previous[j]) || continue
                for i in 1:n
                    candidate=matrix[i,j]+previous[j]
                    if candidate<current[i]
                        current[i]=candidate;successors[i,hop]=j
                    end
                end
            end
            previous=current
        end
        for d in 1:D
            data.targets[d]==target || continue
            lower[d]=previous[data.sources[d]]
            path=Int[data.sources[d]];vertex=data.sources[d]
            for hop in K:-1:1
                j=successors[vertex,hop]
                j==0 && continue
                push!(path,j);vertex=j
            end
            pairs=collect(zip(path,path[2:end]))
            last(path)==target && length(unique(pairs))==length(pairs) && (paths[d]=path)
        end
    end
    return (;complete=true,lower,paths)
end

# ╔═╡ a4a33462-4a02-4e36-b9e3-de7208ecc704
function fast_time01_pair_sweep!(columns,keys,data,prices;deadline=Inf,max_columns=100_000)
    # Independent-period walks and common-route walks relax the full pricing domain.
    D=length(data.sources)
    separate=[time01_hop_prices(data,prices.physical[t+1];deadline,period=t) for t in 0:1]
    all(p.complete for p in separate) || return (;complete=false,lower_bounds=copy(prices.floors),added=0,visited=0)
    grid=[0.,.25,.5,.75,1.]
    common=[time01_hop_prices(data,rho.*prices.physical[1].+(1-rho).*prices.physical[2];deadline) for rho in grid]
    all(p.complete for p in common) || return (;complete=false,lower_bounds=copy(prices.floors),added=0,visited=0)
    lower_bounds=copy(prices.floors);added=0
    for d in 1:D
        v0=data.v[d,0];v1=data.v[d,1];total=v0+v1
        rho=total>0 ? v0/total : .5
        left=min(length(grid)-1,max(1,searchsortedlast(grid,rho)))
        fraction=(rho-grid[left])/(grid[left+1]-grid[left])
        common_bound=total*((1-fraction)*common[left].lower[d]+fraction*common[left+1].lower[d])
        separate_bound=v0*separate[1].lower[d]+v1*separate[2].lower[d]
        # Distinct binary segment sets with identical flow balance differ in at least two arcs.
        change_floor=prices.mu>=0 ? 2prices.mu : 2data.MaxSeg*prices.mu
        price_bound=data.budget<2 ? common_bound : min(common_bound,separate_bound+change_floor)
        isfinite(price_bound) && (lower_bounds[d]=max(lower_bounds[d],price_bound-1e-9*(1+abs(price_bound))))
        choices=Tuple{Vector{Int},Vector{Int}}[]
        push!(choices,(separate[1].paths[d],separate[2].paths[d]))
        for p in common
            push!(choices,(p.paths[d],p.paths[d]))
        end
        for (p0,p1) in choices
            (isempty(p0)||isempty(p1)) && continue
            objective=sum(data.v[d,t-1]*prices.physical[t][i,j] for (t,path) in enumerate((p0,p1)) for (i,j) in zip(path,path[2:end]))+prices.mu*segment_change_count(p0,p1)
            if objective-prices.alpha[d]<-1e-8
                accepted=add_time01_pair!(columns,keys,data,d,p0,p1;max_columns)
                added+=accepted>0
            end
        end
    end
    return (;complete=true,lower_bounds,added,visited=D)
end

# ╔═╡ 808282e4-beeb-4bd3-abaf-383f793aa79b
function time01_pair_duals(data,master)
    m=length(data.arcs);n=length(data.node_ids)
    weights=-dual.(master.load_rows);mu=-dual(master.budget_row);alpha=dual.(master.convexity)
    physical=[reshape(data.periods[t+1].r.values*(weights[t*m+1:(t+1)*m]./data.c),n,n) for t in 0:1]
    minima=[min(0.,minimum(matrix)) for matrix in physical]
    floors=[data.MaxSeg*sum(data.v[d,t-1]*minima[t] for t in 1:2)+min(0.,2data.MaxSeg*mu) for d in eachindex(data.sources)]
    return (;weights,mu,alpha,physical,floors,dual_value=dual_objective_value(master.model))
end

# ╔═╡ c37c7fe1-924d-48d0-85a8-3935d7ed0127
function time01_pair_bound(prices,lower_bounds)
    all(isfinite,lower_bounds) || error("Nonfinite pair pricing bound")
    correction=sum(min(0.,lower_bounds[d]-prices.alpha[d]) for d in eachindex(lower_bounds))
    safety=1e-8*(1+abs(prices.dual_value)+sum(abs,prices.alpha)+sum(abs,prices.weights)+abs(prices.mu))
    return max(0.,prices.dual_value+correction-safety)
end

# ╔═╡ ddbf4545-1840-4180-9b66-2ca16b16a2ac
md"""
### `validate_time01_pairs` and `start_time01_pair_master!` — independent feasibility

Rebuilds the two period selections and invokes the original validator, which recomputes r*v/c loads and symmetric-difference Budget from the paths. Pool costs and solver auxiliaries are not trusted. The master warm start uses that validated incumbent. It does not freeze any demand permanently.
"""

# ╔═╡ 70dd1245-04b7-4d27-8cd5-83a4f69c2bb4
function validate_time01_pairs(data,columns,selection)
    D=length(data.sources)
    length(selection)==D || error("Missing demand pair")
    all(columns[selection[d]].d==d for d in 1:D) || error("Wrong demand pair selection")
    flat=vcat([columns[selection[d]].period_columns[1] for d in 1:D],
        [columns[selection[d]].period_columns[2] for d in 1:D])
    validation=validate_time01_selection(data,flat,collect(1:2D))
    return merge(validation,(selection=collect(selection),))
end

# ╔═╡ bea594f2-b8f8-49dd-a356-e324b775ebbe
function start_time01_pair_master!(master,validation)
    chosen=Set(validation.selection)
    for p in eachindex(master.y)
        set_start_value(master.y[p],p in chosen ? 1. : 0.)
    end
    for a in eachindex(master.loads)
        set_start_value(master.loads[a],validation.loads[a])
    end
    set_start_value(master.z,validation.mlu)
    return nothing
end

# ╔═╡ a0f3d2ae-3024-4988-abe7-575e81bc9f47
md"""
### `solve_time01_pairs` — root master–pricing, then a restricted integer solve

Starts with one feasible direct/direct pair per demand. `seed_time01_pairs!` can also load saved time-0 routes as identical pairs in both periods (Budget cost zero), revalidate their reachability and physical loads, and use the better feasible start. These routes are only optional candidates; they impose no route restriction. Each cycle solves a restricted LP, prices pairs independently by demand, adds negative-reduced-cost columns, and solves a restricted binary master for an incumbent. If no improving column is generated while a global gap remains, a diversification pass excludes existing pair incidences to discover additional integer-useful columns; its restricted pricing bounds never enter the global bound.

Previously certified top-k values remain locked. MLU gap 10% is only reported; it does not stop search. The shared budget counts master LP, pricing, diversification and master MIP optimize calls. A separate wall guard and variable/column guards bound non-solver work. Restricted integer bounds are logged but never treated as full-domain bounds. This is not branch-and-price: an LP/integer gap can prevent certification even after LP pricing converges. The former separate-period implementation remains callable as `solve_time01_separate` for regression comparison.
"""

# ╔═╡ eb02b7e9-ddfd-4e6c-ad77-7fd298565bb5
function seed_time01_pairs!(columns,keys,data;max_columns=100_000,warm_start_file="")
    isempty(warm_start_file) && return nothing
    isfile(warm_start_file) || return nothing
    saved=JSON3.read(read(warm_start_file,String))
    indices=Dict(id=>i for (i,id) in enumerate(data.node_ids))
    routes=Dict(Int(r.d)=>r.w for r in saved.srpaths if Int(r.t)==0)
    selection=collect(1:length(data.sources))
    for d in eachindex(data.sources)
        haskey(routes,data.demand_ids[d]) || continue
        path=vcat(data.sources[d],[indices[Int(id)] for id in routes[data.demand_ids[d]]],data.targets[d])
        pairs=collect(zip(path,path[2:end]))
        all(data.periods[2].counts[i,j]>0 for (i,j) in pairs) || continue
        accepted=add_time01_pair!(columns,keys,data,d,path,path;max_columns)
        if accepted>0
            selection[d]=accepted
        else
            found=findfirst(c->c.d==d && c.paths==(path,path),columns)
            found===nothing || (selection[d]=found)
        end
    end
    return validate_time01_pairs(data,columns,selection)
end

# ╔═╡ 48ad4fbb-0400-4764-ab7f-1b56a5144cbf
function solve_time01_pairs(data;time_limit=3600.,solver=:highs,seed=1,threads=1,target_gap=.10,
        lock_tolerance=1e-7,proof_tolerance=2e-6,max_variables=2_000_000,max_columns=100_000,
        max_pricing_variables=200_000,pricing_slice=2.,pair_pricing=:auto,warm_start_file="",log_file="",solution_file="")
    isfinite(time_limit)&&time_limit>0 && pricing_slice>0 || error("Invalid pair solve time limits")
    max_columns>=length(data.sources) || error("Pair pool cannot hold initial solution")
    isempty(log_file) || mkpath(dirname(abspath(log_file)))
    isempty(solution_file) || mkpath(dirname(abspath(solution_file)))
    pricing_log=isempty(log_file) ? "" : splitext(log_file)[1]*"_pricing.csv"
    for path in (log_file,pricing_log)
        isempty(path) || !isfile(path) || rm(path)
    end
    lock(ORANGE_SOLVER_LOCK)
    try
        HiGHS.Highs_resetGlobalScheduler(1)
        started=time();elapsed=0.;lp_total=0.;pricing_total=0.;mip_total=0.;nodes=0;pricing_nodes=0
        D=length(data.sources);M=2length(data.arcs)
        pair_pricing in (:auto,:dynamic,:milp) || error("Invalid pair pricing method")
        dynamic=pair_pricing==:dynamic || (pair_pricing==:auto && length(data.node_ids)>12)
        data=merge(data,(pair_ratios=[sparse(transpose(p.r.values)) for p in data.periods],))
        pricing_wall_total=0.
        wall_allowance=dynamic ? 2time_limit+300. : time_limit+max(30.,.1time_limit)
        columns=NamedTuple[];keys=[Set{Tuple}() for d in 1:D]
        for d in 1:D
            path=[data.sources[d],data.targets[d]]
            add_time01_pair!(columns,keys,data,d,path,path;max_columns)
        end
        validation=validate_time01_pairs(data,columns,collect(1:D))
        warm=seed_time01_pairs!(columns,keys,data;max_columns,warm_start_file)
        warm!==nothing && warm.mlu<validation.mlu && (validation=warm)
        isempty(log_file) || (println("Paired start | MLU=",validation.mlu," | pairs=",length(columns)," | pricing=",dynamic ? "dynamic" : "milp");flush(stdout))
        endpoint=dynamic ? time01_endpoint_bound(data;time_limit=min(30.,.15time_limit),seed,threads) : (bound=0.,seconds=0.,nodes=0,visited=0)
        elapsed+=endpoint.seconds;nodes+=endpoint.nodes
        endpoint.bound<=validation.mlu+proof_tolerance || error("Endpoint bound exceeds incumbent")
        isempty(log_file) || (println("Endpoint global MLU bound=",endpoint.bound," | optimize_seconds=",endpoint.seconds);flush(stdout))
        locks=Float64[];completed=0;k=1;cycle=0;stage_bound=endpoint.bound;first_bound=endpoint.bound
        termination="TIME_LIMIT";status="Not Optimal";pricing_calls=0
        last_lp_closed=false;last_visited=0;restricted_bound=missing;last_bound=0.
        while k<=M && time_limit-elapsed>1e-3
            time()-started>wall_allowance && (termination="SEARCH_WALL_LIMIT";break)
            cycle+=1;remaining=time_limit-elapsed;added=0;visited=0;cycle_pricing=0.;cycle_lp=0.;cycle_mip=0.;mip_status="NOT_RUN"
            slice=min(10.,remaining*.20)
            master=build_time01_pair_master(data,columns,k,locks;time_limit=slice,seed,max_variables)
            prices=nothing
            try
                install_highs_deadline!(master.model,slice)
                seconds=@elapsed optimize!(master.model);elapsed+=seconds;lp_total+=seconds;cycle_lp=seconds
                if termination_status(master.model)==ORANGE_MOI.OPTIMAL && dual_status(master.model)==ORANGE_MOI.FEASIBLE_POINT
                    prices=time01_pair_duals(data,master)
                end
            finally
                empty!(master.model)
            end
            closed=false
            if prices!==nothing
                lower_bounds=copy(prices.floors)
                if dynamic
                    pricing_started=time()
                    sweep=fast_time01_pair_sweep!(columns,keys,data,prices;
                        deadline=started+wall_allowance,max_columns)
                    pricing_wall_total+=time()-pricing_started
                    lower_bounds=sweep.lower_bounds;added+=sweep.added;visited=sweep.visited
                    pricing_calls+=sweep.visited
                    isempty(pricing_log) || append_result_csv(pricing_log,
                        (stage=k,cycle,demand_index=0,demand_id=0,mode="dynamic_all_demands",status=sweep.complete ? "COMPLETE" : "INTERRUPTED",
                         minimum_lower_bound=minimum(lower_bounds),candidate_reduced_cost=missing,added=sweep.added>0,
                         optimize_seconds=0.,cumulative_optimize_seconds=elapsed))
                end
                for d in (dynamic ? (1:0) : (1:D))
                    remaining=time_limit-elapsed
                    remaining<=.01 && break
                    time()-started>wall_allowance && break
                    slice=min(pricing_slice,remaining*.5/(D-d+1))
                    price=try
                        price_time01_demand(data,d,prices.physical,prices.mu;time_limit=slice,solver,seed,threads,
                            max_variables=min(max_variables,max_pricing_variables))
                    catch exception
                        occursin("MODEL_SIZE_LIMIT",sprint(showerror,exception)) || rethrow()
                        (d=d,seconds=0.,status="MODEL_SIZE_LIMIT",lower_bound=missing,candidate=nothing,nodes=0)
                    end
                    elapsed+=price.seconds;pricing_total+=price.seconds;cycle_pricing+=price.seconds;pricing_calls+=1;pricing_nodes+=price.nodes;visited+=1
                    if !ismissing(price.lower_bound)
                        lower_bounds[d]=max(lower_bounds[d],price.lower_bound-1e-7*(1+abs(price.lower_bound)))
                    end
                    reduced=price.candidate===nothing ? missing : price.candidate.objective-prices.alpha[d]
                    accepted=0
                    if !ismissing(reduced) && reduced < -1e-8
                        c=price.candidate
                        accepted=add_time01_pair!(columns,keys,data,d,c.path0,c.path1;max_columns)
                        added+=accepted>0
                    end
                    row=(stage=k,cycle,demand_index=d,demand_id=data.demand_ids[d],mode="reduced_cost",status=price.status,
                        minimum_lower_bound=lower_bounds[d],candidate_reduced_cost=reduced,added=accepted>0,
                        optimize_seconds=price.seconds,cumulative_optimize_seconds=elapsed)
                    isempty(pricing_log) || append_result_csv(pricing_log,row)
                end
                stage_bound=max(stage_bound,time01_pair_bound(prices,lower_bounds))
                closed=all(lower_bounds[d]>=prices.alpha[d]-1e-7 for d in 1:D)
            end
            last_lp_closed=closed;last_visited=visited
            value_now=sum(sort(validation.loads;rev=true)[1:k]);restricted_bound=missing
            if time_limit-elapsed>.01 && value_now-stage_bound>proof_tolerance
                slice=min(10.,(time_limit-elapsed)*.5)
                master=build_time01_pair_master(data,columns,k,locks;integer=true,solver,time_limit=slice,seed,threads,max_variables)
                try
                    start_time01_pair_master!(master,validation)
                    solver==:highs && install_highs_deadline!(master.model,slice)
                    seconds=@elapsed optimize!(master.model);elapsed+=seconds;mip_total+=seconds;cycle_mip=seconds;nodes+=node_count(master.model);mip_status=string(termination_status(master.model))
                    bound=objective_bound(master.model)
                    isfinite(bound)&&abs(bound)<1e19 && (restricted_bound=bound)
                    if primal_status(master.model)==ORANGE_MOI.FEASIBLE_POINT
                        all(abs(value(y)-round(value(y)))<1e-5 for y in master.y) || error("Nonbinary pair master")
                        selection=[only([p for p in master.bygroup[d] if value(master.y[p])>.5]) for d in 1:D]
                        candidate=validate_time01_pairs(data,columns,selection)
                        vector=sort(candidate.loads;rev=true)
                        all(sum(vector[1:j])<=locks[j]+1e-5 for j in eachindex(locks)) || error("Pair master violates prior lock")
                        if sum(vector[1:k])<=value_now+1e-7
                            validation=candidate;value_now=sum(vector[1:k])
                        end
                    end
                finally
                    empty!(master.model)
                end
            end
            stage_bound<=value_now+proof_tolerance || error("Pair global bound exceeds incumbent")
            k==1 && (first_bound=max(first_bound,stage_bound))
            certified=value_now-stage_bound<=proof_tolerance
            if !certified && added==0 && prices!==nothing && !dynamic
                for d in 1:D
                    remaining=time_limit-elapsed
                    remaining<=.01 && break
                    time()-started>wall_allowance && break
                    slice=min(pricing_slice,remaining*.25/(D-d+1))
                    price=try
                        price_time01_demand(data,d,prices.physical,prices.mu;time_limit=slice,solver,seed,threads,
                            max_variables=min(max_variables,max_pricing_variables),exclude_pairs=[c for c in columns if c.d==d])
                    catch exception
                        occursin("MODEL_SIZE_LIMIT",sprint(showerror,exception)) || rethrow()
                        (d=d,seconds=0.,status="MODEL_SIZE_LIMIT",lower_bound=missing,candidate=nothing,nodes=0)
                    end
                    elapsed+=price.seconds;pricing_total+=price.seconds;cycle_pricing+=price.seconds;pricing_calls+=1;pricing_nodes+=price.nodes
                    accepted=0
                    if price.candidate!==nothing
                        c=price.candidate
                        accepted=add_time01_pair!(columns,keys,data,d,c.path0,c.path1;max_columns)
                        added+=accepted>0
                    end
                    row=(stage=k,cycle,demand_index=d,demand_id=data.demand_ids[d],mode="diversify",status=price.status,
                        minimum_lower_bound=missing,candidate_reduced_cost=price.candidate===nothing ? missing : price.candidate.objective-prices.alpha[d],
                        added=accepted>0,optimize_seconds=price.seconds,cumulative_optimize_seconds=elapsed)
                    isempty(pricing_log) || append_result_csv(pricing_log,row)
                end
            end
            row=(stage=k,cycle,objective=value_now,global_bound=stage_bound,gap=experiment_gap(value_now,stage_bound),
                globally_certified=certified,pair_columns=length(columns),new_columns=added,pricing_demands=visited,
                pricing_lp_closed=closed,restricted_integer_bound=restricted_bound,budget_used=validation.cost,
                lp_seconds=cycle_lp,pricing_seconds=cycle_pricing,mip_seconds=cycle_mip,mip_status,
                master_nodes=nodes,pricing_nodes,cumulative_optimize_seconds=elapsed)
            isempty(log_file) || append_result_csv(log_file,row)
            last_bound=stage_bound
            if certified
                completed=k;push!(locks,value_now+lock_tolerance);k+=1;cycle=0;stage_bound=0.
            elseif length(columns)>=max_columns
                termination="ROUTE_POOL_LIMIT";break
            end
            if !isempty(solution_file)
                payload=(srpaths=validation.srpaths,validated=true,budget_used=validation.cost,budget=data.budget,
                    mlu=validation.mlu,global_mlu_bound=first_bound,lex_completed_stages=completed,lex_total_stages=M,
                    termination="RUNNING",formulation="paired_demand_master_pricing",sorted_loads=sort(validation.loads;rev=true))
                write(solution_file*".tmp",JSON3.write(payload));mv(solution_file*".tmp",solution_file;force=true)
            end
        end
        completed==M && (status="Optimal";termination="OPTIMAL")
        gap=experiment_gap(validation.mlu,first_bound)
        result=(status,termination,objective=validation.mlu,lower_bound=first_bound,gap,validated=true,
            budget_used=validation.cost,budget=data.budget,lex_completed_stages=completed,lex_total_stages=M,
            active_stage=min(k,M),stage_lower_bound=k>M ? last_bound : stage_bound,stage_objective=sum(sort(validation.loads;rev=true)[1:min(k,M)]),
            cpu_time_seconds=elapsed,wall_time_seconds=time()-started,columns=length(columns),pool_complete=false,nodes,pricing_nodes,total_nodes=nodes+pricing_nodes,
            mlu_target_met=!ismissing(gap)&&gap<=target_gap,sorted_loads=sort(validation.loads;rev=true),srpaths=validation.srpaths,
            solver=String(solver),solver_version=orange_solver_version(solver),objective_mode="lexicographic_all_arcs_all_periods",
            formulation="paired_demand_master_pricing",bound_scope="full_pair_domain_lp_correction",pricing_lp_closed=last_lp_closed,
            pricing_demands_last_sweep=last_visited,pricing_calls,pricing_optimize_seconds=pricing_total,
            lp_optimize_seconds=lp_total,mip_optimize_seconds=mip_total,pricing_wall_seconds=pricing_wall_total,
            pair_pricing=String(dynamic ? :dynamic : :milp),endpoint_lower_bound=endpoint.bound,
            endpoint_optimize_seconds=endpoint.seconds,endpoint_groups=endpoint.visited,restricted_integer_bound=restricted_bound,
            lock_tolerance,proof_tolerance,log_file,pricing_log,solution_file)
        if !isempty(solution_file)
            write(solution_file*".tmp",JSON3.write(result));mv(solution_file*".tmp",solution_file;force=true)
        end
        return result
    finally
        unlock(ORANGE_SOLVER_LOCK)
    end
end

# ╔═╡ e4bdc34f-6047-4a4f-88ca-d8700bc8a48b
md"""
### `solve_time01` — select the paired implementation explicitly or by default

The default is now `:paired`. `:separate` retains the former implementation for regression checks. Both use identical Data, Budget and joint lexicographic objectives. Result metadata distinguishes the formulations; completed-run checkpoints must not be mixed.
"""

# ╔═╡ ed7fcf70-99f8-480a-b3c0-c5a11617d741
function solve_time01(data;formulation=:paired,kwargs...)
    formulation==:paired && return solve_time01_pairs(data;kwargs...)
    formulation==:separate && return solve_time01_separate(data;kwargs...)
    error("Choose time01 formulation :paired or :separate")
end

# ╔═╡ 51a413b5-7a55-410a-b287-12f5e5d52343
md"""
## Execute paired demand decomposition on the official example

The following short local demonstration reports the actual generated pool, global bound, Budget, pricing calls and certified prefix. Unlike the separate-pool exhaustive reference demonstration, it need not certify all 44 stages within its short budget. An integer optimum on a restricted pool is never reported as a full optimum unless a global bound certifies every stage.
"""

# ╔═╡ bbf62fd6-91f6-4402-8228-a2f2f57ffb0a
orange_paired_demo_result=solve_time01(orange_time01_demo_data;time_limit=3.)

# ╔═╡ 07729ea6-f15e-4c4f-82b1-0a059a969226
(status=orange_paired_demo_result.status,mlu=orange_paired_demo_result.objective,
 budget_used=orange_paired_demo_result.budget_used,budget=orange_paired_demo_result.budget,
 certified_stages=orange_paired_demo_result.lex_completed_stages,total_stages=orange_paired_demo_result.lex_total_stages,
 pair_columns=orange_paired_demo_result.columns,pricing_calls=orange_paired_demo_result.pricing_calls,
 global_mlu_bound=orange_paired_demo_result.lower_bound,gap=orange_paired_demo_result.gap,
 optimize_seconds=orange_paired_demo_result.cpu_time_seconds,formulation=orange_paired_demo_result.formulation)

# ╔═╡ 81255cde-5365-4998-843c-7160bf4dbfb4
md"""
## Two-period experiment runner — disabled unless explicitly invoked

`run_time01_experiments` uses original SetA JSONs, both periods and the scenario's actual Budget. Defaults match the extended experiment's 3600-second shared optimize budget. Each result records the joint MLU and global bound, actual Budget usage, full lexicographic progress, dimensions, seeds, solver, time and checkpoint paths. It does not replace Step 6 or silently shorten repetitions. Completed runs resume only under identical configuration. Errors and allocation guards remain unexecuted/Not Optimal, not proofs of infeasibility.
"""

# ╔═╡ d07eddbd-9325-4260-9d60-8aacafe1a82a
function run_time01_experiments(;instances=1:20,runs=10,time_limit=3600.,solver=:highs,
        output_dir=joinpath(@__DIR__,"results","time01_highs"),seed_base=1000,threads=1,run_start=1,
        max_variables=2_000_000,max_columns=100_000,formulation=:paired,max_pricing_variables=200_000,pricing_slice=2.,pair_pricing=:auto,
        warm_start_dir=joinpath(@__DIR__,"warm_starts"))
    formulation in (:paired,:separate) || error("Choose :paired or :separate")
    ids=collect(Int,instances)
    !isempty(ids)&&all(i->1<=i<=20,ids)&&length(unique(ids))==length(ids) || error("Invalid SetA selection")
    runs>=1 && run_start>=1 || error("Invalid repetition count")
    mkpath(output_dir)
    config=(schema_version=4,formulation=String(formulation),max_pricing_variables,pricing_slice,pair_pricing=String(pair_pricing),warm_start_dir,periods=[0,1],objective="lexicographic_all_arcs_all_periods",splitting="ecmp",
        instances=ids,runs,run_start,time_limit,solver=String(solver),seed_base,threads,max_variables,max_columns)
    config_file=joinpath(output_dir,"config.json")
    text=JSON3.write(config)
    isfile(config_file) && read(config_file,String)!=text && error("Use a new directory: temporal settings differ")
    write(config_file,text)
    rows=NamedTuple[];csv=joinpath(output_dir,"runs.csv")
    isfile(csv) && rm(csv)
    for id in ids
        instance="setA-"*lpad(id,2,'0')
        data=load_time01_data(joinpath(@__DIR__,"setA",instance))
        for run in run_start:run_start+runs-1
            base=joinpath(output_dir,instance*"_run-"*lpad(run,2,'0'))
            checkpoint=base*".json"
            if isfile(checkpoint)
                saved=JSON3.read(read(checkpoint,String))
                row=(;(Symbol(k)=>(isnothing(v) ? missing : v) for (k,v) in pairs(saved))...)
            else
                result=try
                    solve_time01(data;time_limit,solver,seed=seed_base+run,threads,max_variables,max_columns,formulation,
                        (formulation==:paired ? (;max_pricing_variables,pricing_slice,pair_pricing,
                            warm_start_file=joinpath(warm_start_dir,instance*"_time0.json")) : NamedTuple())...,
                        log_file=base*"_cycles.csv",solution_file=base*"_solution.json")
                catch exception
                    exception isa InterruptException && rethrow()
                    message=sprint(showerror,exception)
                    (status="Not Optimal",termination=occursin("MODEL_SIZE_LIMIT",message) ? "MODEL_SIZE_LIMIT" : "ERROR",
                        objective=missing,lower_bound=missing,gap=missing,validated=false,budget_used=missing,
                        lex_completed_stages=0,lex_total_stages=2length(data.arcs),cpu_time_seconds=missing,
                        wall_time_seconds=missing,columns=missing,pool_complete=false,nodes=missing,
                        sorted_loads=Float64[],error=message)
                end
                row=(instance,run,seed=seed_base+run,periods="0,1",solver=String(solver),solver_version=orange_solver_version(solver),
                    vertices=length(data.node_ids),links=length(data.arcs),links_time1=ne(data.graphs[2]),demands=length(data.sources),
                    budget=data.budget,budget_used=result.budget_used,status=result.status,termination=result.termination,
                    objective=result.objective,lower_bound=result.lower_bound,gap=result.gap,validated=result.validated,
                    lex_completed_stages=result.lex_completed_stages,lex_total_stages=result.lex_total_stages,
                    cpu_time_seconds=result.cpu_time_seconds,wall_time_seconds=result.wall_time_seconds,nodes=result.nodes,
                    candidate_columns=result.columns,pool_complete=result.pool_complete,formulation=String(formulation),
                    pricing_calls=hasproperty(result,:pricing_calls) ? result.pricing_calls : missing,
                    pricing_nodes=hasproperty(result,:pricing_nodes) ? result.pricing_nodes : missing,
                    lp_optimize_seconds=hasproperty(result,:lp_optimize_seconds) ? result.lp_optimize_seconds : missing,
                    pricing_optimize_seconds=hasproperty(result,:pricing_optimize_seconds) ? result.pricing_optimize_seconds : missing,
                    mip_optimize_seconds=hasproperty(result,:mip_optimize_seconds) ? result.mip_optimize_seconds : missing,
                    endpoint_lower_bound=hasproperty(result,:endpoint_lower_bound) ? result.endpoint_lower_bound : missing,
                    endpoint_optimize_seconds=hasproperty(result,:endpoint_optimize_seconds) ? result.endpoint_optimize_seconds : missing,
                    pricing_wall_seconds=hasproperty(result,:pricing_wall_seconds) ? result.pricing_wall_seconds : missing,
                    pair_pricing=hasproperty(result,:pair_pricing) ? result.pair_pricing : "separate",
                    bound_scope=hasproperty(result,:bound_scope) ? result.bound_scope : "separate_reference_or_error",
                    sorted_loads_json=JSON3.write(result.sorted_loads),solution_file=base*"_solution.json",
                    error=hasproperty(result,:error) ? result.error : "")
                write(checkpoint*".tmp",JSON3.write(row));mv(checkpoint*".tmp",checkpoint;force=true)
            end
            push!(rows,row);append_result_csv(csv,row)
            println(instance," run ",run,": ",row.status," | ",row.termination," | Budget=",row.budget_used,"/",row.budget)
            flush(stdout)
        end
    end
    return (;rows,output_dir=abspath(output_dir))
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
# ╟─883a391a-2e6e-4b9f-b03c-3416b8e13482
# ╠═1c1bff3e-050a-40b7-8799-9fe482e0dc5a
# ╠═19285b33-616b-409e-8481-1306f86498a8
# ╠═fa63c98d-74b0-477c-ab15-261bb423b147
# ╠═3c6a6416-d8c3-4169-b572-a8ffbd82eed5
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
# ╟─0f630d76-c12e-4d83-a7a8-95a2eace1262
# ╠═ff5ffe39-dfc4-4ccf-9c44-f9d16548f205
# ╠═18d27926-6238-4933-a5f1-63b02bc39d1b
# ╠═79524299-953d-4ea5-99ea-c5f555c2c73f
# ╟─4ad642fe-2c86-4d74-979a-b48d657f2917
# ╟─78a0ae6d-a64b-4f25-abb2-40bd06ab6e26
# ╠═07d9e8b5-b949-4581-b3ca-a13eac2f28f4
# ╠═43a769d5-c2db-451a-a2b1-dc3852794675
# ╟─c77ef705-5cf7-4fda-ac94-508bf8193134
# ╠═534fb5b2-9055-42ea-ac95-68d7919bd7fc
# ╠═8b667b30-fffd-4231-97c4-a300612c4ffd
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
# ╟─469bf80a-c389-4ea0-8187-1a8fc6e8037a
# ╟─c3ed0cf3-8514-47da-9930-6c719844eb6a
# ╠═426ef93a-1177-4113-85be-a2013131b5e4
# ╟─b9b4c5be-a1f0-4a58-b88f-b6ca02da8616
# ╠═0e5bf6a1-e6d9-4517-bce7-eab1bccefe90
# ╟─f72de83e-7527-456c-a302-cfa339323893
# ╠═04cf4dfd-193b-4737-b8d8-d040611338e7
# ╟─2e4328cc-785e-44ed-b548-4f4b920e7f7b
# ╠═fe4bdc91-0eb6-40bc-8cba-7ebfaa7334a3
# ╟─478f3c47-d0a9-4075-935f-0d122c393cb5
# ╠═49fcd1cc-3ad0-4588-bc31-5a12f9c31ca6
# ╟─48e92439-c8b4-4dc7-bc07-588959337922
# ╠═b54c1180-cf5e-405a-9b4d-7e6905b570de
# ╟─74d13c6e-0d13-4c34-868f-b9a485687a80
# ╠═31a7b7be-dc05-4f55-887c-82a71cb6abae
# ╟─68d3cd68-1300-4f1f-ae75-a6d82dab0e58
# ╠═7d35907e-afc6-4cac-bee4-d3885f4f2459
# ╟─a5aab9a2-4359-40a7-85f4-22a4f4715d11
# ╠═92a75acf-fcb1-4e18-99da-4c62568c8af8
# ╟─ecb8cc09-f4f3-40c9-a104-fcb8760fadf1
# ╠═da4dedcf-d034-4ad3-8b32-eac230815a68
# ╟─536bfb31-5629-4273-b0ec-0adf06d8bb62
# ╠═3186551c-93ef-4462-803f-1c1b0f061c8f
# ╟─5e8da978-1cd6-4f7f-b72c-3df3ed413c2f
# ╠═f137ffe6-5823-486f-bbed-f328dab305a8
# ╟─16cb313f-d096-4c3f-a798-3a3974b914a1
# ╠═af329d02-2385-412a-9f94-779afa8bae64
# ╟─8e4569ee-47a2-4cbf-83b2-25cfa73bb5c8
# ╟─df89efc2-fa06-43c1-bfdb-c6ea609b28cb
# ╠═ae65ba8d-0472-4b3c-86be-d0c16f88a187
# ╠═91f7c7d3-c219-40e3-bb4c-7517478f94b8
# ╟─82029e20-1987-451e-a27f-bd24c61809c0
# ╟─1c462a22-e6f0-4ef7-8c8b-560780682355
# ╠═e80fae9f-d0c0-4be7-b391-dd8327236ced
# ╟─cf434e7f-4d91-4dc1-8442-fe30f9e6af52
# ╠═ef4be839-72c5-46f0-a574-c18135b6eb47
# ╠═de3e2d40-0941-490c-983b-d614c4090f41
# ╟─79b800a9-48e4-45a8-b597-9b8076728465
# ╠═b3659101-8e23-406c-96ca-a80b36579c7c
# ╠═f1b17671-4b54-4b2b-9231-20300509c373
# ╟─bc2aa034-eec5-4be9-8e67-f42e53274e97
# ╠═0b8dc725-5f9e-4bb8-b28f-39ea4d795bec
# ╟─2b4d01b6-060a-4a1f-a746-b11e7600a3c9
# ╠═32f0ec3c-773f-4935-9c7c-c6efa67af057
# ╟─15eb46ca-9e71-4253-88f5-1a27e44cbf30
# ╠═77d88db4-3a6d-43ec-bd57-89a3ce8a614b
# ╟─bd9a019c-a5f2-49d6-9866-ffe672b17684
# ╟─91725283-c491-4833-8761-f3392001721e
# ╠═5cea359a-93dc-484a-b9fa-7506880410cf
# ╟─f21f8c26-ef05-420d-9084-f9e19c57ef81
# ╠═a7f93306-bc7c-45f6-a236-fc02a64a4dcd
# ╟─58534b35-038a-4589-8911-c9266655d42c
# ╠═e72379af-2de9-4b3b-bcc1-35b1cbaf32ee
# ╟─7003ce69-5a05-4db5-b8ca-a71b15ab0061
# ╠═c86c4c6c-6816-4b47-abe1-9d4f53ee102f
# ╟─728107f3-38e8-49eb-82cd-ac3556a23c02
# ╠═266dfd3f-b287-49d7-9a3a-65892b36c770
# ╟─824855af-6248-4b15-9578-ba9b06881abe
# ╠═1958d2c4-f17f-4dfc-8905-a4ea32570430
# ╟─77eb45a4-a033-4906-afac-c5eedf0618bf
# ╠═8c2c269f-ae46-4281-a5de-7aacde226a8e
# ╟─73bd06cb-46f4-4575-bf95-df966b1249dc
# ╠═24e03d85-549e-4048-a07b-c76c927c239f
# ╟─12515315-5f71-4eb4-b405-5ca901ebffcb
# ╠═a1f95b24-c1c5-478c-936a-63b90b602562
# ╠═ca0e6c98-d6ee-47a4-b9b6-dbe3caabb914
# ╠═447f38c1-525b-46e8-ac64-d13624aad031
# ╠═35b21d5d-99f6-443f-87f4-2a4a16c8a081
# ╟─a8210754-6806-4466-a97f-c27323f6ac3d
# ╟─bfa1a8c7-e37e-4959-ad89-d12eed9a827b
# ╠═89e8fe74-8770-4a9f-a26c-abe0f33a940f
# ╠═86d52d2f-1256-46d9-8b22-0ac58e705fd3
# ╟─ecd1fc1a-8f22-47a7-bd14-f42ac885c3d2
# ╠═ecb40588-559b-45c1-a321-c17fa002f441
# ╟─078626be-dbe4-46d9-85cc-b3746fdab7bc
# ╠═5ad94785-6cdf-47df-aa5c-32f620439eae
# ╟─1e8b54ae-325c-4e54-a2cc-057ee34c0ac9
# ╠═2fdaf07d-a848-4cb3-ba89-b73e572c1e82
# ╟─23f76f06-9035-477c-9478-69808a03c56c
# ╟─6182b0cb-c9dd-4d99-b81f-a83b853fa6a3
# ╠═1e6d2f6f-ba1d-43f7-93b4-702a437e8936
# ╠═a4a33462-4a02-4e36-b9e3-de7208ecc704
# ╠═808282e4-beeb-4bd3-abaf-383f793aa79b
# ╠═c37c7fe1-924d-48d0-85a8-3935d7ed0127
# ╟─ddbf4545-1840-4180-9b66-2ca16b16a2ac
# ╠═70dd1245-04b7-4d27-8cd5-83a4f69c2bb4
# ╠═bea594f2-b8f8-49dd-a356-e324b775ebbe
# ╟─a0f3d2ae-3024-4988-abe7-575e81bc9f47
# ╠═eb02b7e9-ddfd-4e6c-ad77-7fd298565bb5
# ╠═48ad4fbb-0400-4764-ab7f-1b56a5144cbf
# ╟─e4bdc34f-6047-4a4f-88ca-d8700bc8a48b
# ╠═ed7fcf70-99f8-480a-b3c0-c5a11617d741
# ╟─51a413b5-7a55-410a-b287-12f5e5d52343
# ╠═bbf62fd6-91f6-4402-8228-a2f2f57ffb0a
# ╠═07729ea6-f15e-4c4f-82b1-0a059a969226
# ╟─81255cde-5365-4998-843c-7160bf4dbfb4
# ╠═d07eddbd-9325-4260-9d60-8aacafe1a82a
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
