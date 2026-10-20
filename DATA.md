# Data notebook

Open `Project_Orange.jl` in Pluto. It is a new, self-contained notebook:
the lecturer's graph-conversion section comes first, followed by the Data section.
No separate implementation notebook needs to be opened or included.

Data contains separate executable steps:

1. Read the matching network, traffic matrix, and scenario JSON files.
2. Reuse the graph and map JSON IDs; display link metrics and capacities `c[a]`.
3. Calculate scaled shortest-path distances and path counts, then show original-unit distances.
4. Calculate `r[i,j,a,t]` with time index `0`, using the formula in calculating_r.pdf.
5. Read and display initial demand volumes `v0[d]` and their endpoints.
6. Read and display `MaxSeg`.
7. Display nonzero routing coefficients and traffic for the first demand.
8. Execute a four-node example verifying `r[1,4,1,0] == 0.5`.

Helper functions are defined separately at notebook scope. `decimal_rational`,
`integer_metric_matrix`, `all_pairs_shortest_data`, and
`ratios_from_shortest_data` each perform a separate operation. `load_data`
combines these operations for batch experiments, but the worked Data section
calls each operation explicitly. No helper is defined inside another function.

`r` is a sparse-backed four-dimensional array. Its time axis is `0:0`.
`c[a]` is capacity, not shortest-path metric. `v0[d]` is the first traffic entry,
corresponding to time 0. JSON identifiers are preserved in `node_ids`, `arc_ids`,
and `demand_ids`; Julia indices start at 1. Arc order follows the JSON link list.

The default routing convention is uniform splitting across complete shortest
paths, as specified in the calculation handout. Optional ECMP splits flow at
each outgoing shortest-path next hop and can produce different coefficients.
All network links are available at time 0. Later periods remain unimplemented.

Verification:

```sh
julia test/runtests.jl
```

The former `src/OrangeData.jl` path is only a compatibility entry point that
includes the combined notebook. Its implementation now lives in the main file.

The lecturer notebook `json_to_graph_pluto_v2.jl` remains separate and contains
only its graph-conversion section. Open `Project_Orange.jl` for the project implementation.

The notebook now also contains the full time-0 lexicographic mathematical model
and experiment runner. See `EXPERIMENTS.md` for execution and result interpretation.

SCIP is now the default optimization backend; select `solver=:highs` or
`--solver highs` for comparison. See the updated experiment guide for separate
output directories, native solver versions, logs and reproducible settings.
