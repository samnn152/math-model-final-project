### A Pluto.jl notebook ###
# v1.0.4

using Markdown
using InteractiveUtils

# ╔═╡ 2cdaf3dd-0a25-4ce2-9da9-4ee017ca9a1b
md"""
# JSON network file → Graphs.jl graph

This Pluto notebook reads a JSON network file with the same structure as
`setA-09-net.json` and converts it into a `Graphs.jl` graph.

Expected JSON structure:

- `directed`: `true` or `false`
- `multigraph`: must be `false`
- `nodes`: objects containing `id` and `name`
- `links`: objects containing `id`, `from`, `to`, `metric`, and `capacity`

The JSON node identifiers may start at 0 (as in the example file). They are
mapped explicitly to Julia/Graphs.jl vertex numbers `1:n`.
"""

# ╔═╡ 7fdb9545-2175-4cf3-862c-ccc4ebd1d627
begin
    using JSON3
    using Graphs
    using SparseArrays
end

# ╔═╡ 705b5e90-5ef4-4285-a46a-4ef4fb0dff01
md"""
## Data structure

`graph` is the actual `Graphs.jl` graph.

The other fields keep the information that is not stored by a
`SimpleGraph` or `SimpleDiGraph`.
"""

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

# ╔═╡ ae531c1a-a653-41bf-879c-799723f2a086
md"""
## Conversion function

The function checks the schema, creates the graph, and preserves the
node/link attributes.
"""

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

# ╔═╡ f09af42c-d81b-4f31-8b7b-9f240c81be6b
md"""
## Helper functions

`edge_attributes(network,u,v)` returns the JSON attributes of a link,
where `u` and `v` are Julia vertex numbers.

`metric_matrix(network)` creates a sparse matrix that can, for example,
be supplied as the distance matrix to shortest-path algorithms.
"""

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

# ╔═╡ 63d45e27-6c5c-4755-9b94-4a7531c85599
md"""
## Read a file

Put the JSON file in the same directory as this notebook and change only
the filename below when needed.
"""

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

# ╔═╡ ee9d2d3e-6d88-4bf0-8038-1e0f9a2cdbee
md"""
## Examples

The JSON node ID `0` is not a Graphs.jl vertex number. Use
`network.id_to_vertex` to convert JSON IDs to Julia vertices.
"""

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

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
Graphs = "86223c79-3864-5bf0-83f7-82e725a168b6"
JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"

[compat]
Graphs = "~1.15.0"
JSON3 = "~1.14.3"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.13.1"
manifest_format = "2.1"
project_hash = "f4a5df33f761f0c912282aa6ab10b8df43cc0337"

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

[[deps.Inflate]]
git-tree-sha1 = "d1b1b796e47d94588b3757fe84fbf65a5ec4a80d"
registries = "General"
uuid = "d25df0c9-e2be-5dd7-82c8-3ad0b3e990b9"
version = "0.1.5"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"
version = "1.11.0"

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

[[deps.JuliaSyntaxHighlighting]]
deps = ["StyledStrings"]
uuid = "ac6e5ff7-fb65-4e79-a425-ec3bc9c03011"
version = "1.12.0"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
version = "1.11.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
version = "1.13.0"

[[deps.MacroTools]]
git-tree-sha1 = "1e0228a030642014fe5cfe68c2c0a818f9e3f522"
registries = "General"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.16"

[[deps.Markdown]]
deps = ["Base64", "JuliaSyntaxHighlighting", "StyledStrings"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"
version = "1.11.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"
version = "1.11.0"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.30+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "b079a6affebde167dad8ffe0d670b53917fbcb68"
registries = "General"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "2.0.3"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "ba0dc8a8a67cacac4842631f960c046e4e563675"
registries = "General"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.8"

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

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "1.0.0"

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

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
version = "1.11.0"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
version = "1.11.0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.15.0+0"

[registries.General]
url = "https://github.com/JuliaRegistries/General.git"
uuid = "23338594-aafe-5451-b93e-139f81909106"
"""

# ╔═╡ Cell order:
# ╟─2cdaf3dd-0a25-4ce2-9da9-4ee017ca9a1b
# ╠═7fdb9545-2175-4cf3-862c-ccc4ebd1d627
# ╟─705b5e90-5ef4-4285-a46a-4ef4fb0dff01
# ╠═7e06044c-4f17-4753-8d29-54fea385e727
# ╠═fee9dcd1-c6f5-46e7-9546-24ba4209efb2
# ╟─ae531c1a-a653-41bf-879c-799723f2a086
# ╠═7ba74f02-ab39-4cce-a008-e456bccf8332
# ╟─f09af42c-d81b-4f31-8b7b-9f240c81be6b
# ╠═41836f74-0f1f-4e99-a4fc-7be3c2f2cc55
# ╠═aa5cf923-9654-4b58-8085-2b66ea3aca47
# ╟─63d45e27-6c5c-4755-9b94-4a7531c85599
# ╠═b58aa673-0039-483f-abd0-337c9b7e0a68
# ╠═72cbbb3d-6002-491b-9559-4d0955e077fb
# ╠═caa9cb28-0c1a-43be-97be-0b54fb06489c
# ╠═db1c3609-d65a-4e95-a215-815052cc27a1
# ╟─ee9d2d3e-6d88-4bf0-8038-1e0f9a2cdbee
# ╠═de136f32-2133-4e18-abef-fbb42cffd537
# ╠═a8bfaf8b-a886-48db-b27b-f68fbdfcc871
# ╠═0286942e-2224-4bad-b162-f3db59b674cb
# ╟─670cc8d4-0867-4838-a7a3-321eab3ce633
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
