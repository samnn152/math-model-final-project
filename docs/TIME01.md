# Periods 0 and 1: implementation and local validation

No GCP resources have been created or started. Cloud configurations are planning inputs; local validation comes first. Full Step 6 and Step 9 batches have not been launched.

## Data

`load_time01_data(prefix)` reads the original three JSON files. At time 1 it removes exactly the directed link IDs listed in interventions with `t=1`. The reverse link is retained unless separately listed. It recomputes shortest paths and next-hop ECMP on the remaining graph, then maps coefficients back into the original arc order:

\[
G_1=(V,A\setminus F_1),\qquad v_{d,1}=\text{demand.v[2]},\qquad
r_{ij a,1}=0\quad(a\in F_1).
\]

The notebook exposes `data.r[i,j,a,t]` and `data.v[d,t]` with time indices `0:1`, both graphs, failed IDs, and an executed official-subject example.

## Joint model and Budget

The original binary segment incidence is retained mathematically:

\[
\sum_jx_{dij,t}-\sum_jx_{dji,t}
=\mathbf1_{i=s_d}-\mathbf1_{i=q_d},\quad
\sum_{ij}x_{dij,t}\le K,\quad
u_{a,t}=\frac1{c_a}\sum_d v_{d,t}\sum_{ij}r_{ija,t}x_{dij,t}.
\]

Unreachable segments are excluded. The reconfiguration constraint is

\[
\sum_{d,i,j}|x_{dij,1}-x_{dij,0}|\le\kappa_1.
\]

`segment_change_count` counts the symmetric difference of **ordered segment sets**. Replacing `(s,q)` by `(s,w),(w,q)` costs 3. Counting only changed waypoints would implement another problem.

For the route formulation, `y[d,p,t]` chooses exactly one route and `x[d,i,j,t]` is its segment incidence. Continuous auxiliaries `h` satisfy `h ≥ x₁−x₀`, `h ≥ x₀−x₁`, `0 ≤ h ≤ 1`, and `Σh ≤ κ₁`. This is the exact absolute-difference constraint on binary incidence. Vertex revisits are allowed when ordered segments are distinct. Removing cycles independently between periods could change Budget and is not used.

The objective is the lexicographic minimum of the sorted union of **all** original arc/time loads. Failed arcs contribute zeros. Sequential stages minimize the sum of the largest `k` loads, retaining earlier optima within documented tolerances. This is a joint objective, not two separately optimized periods.

`build_time01_master` builds a fresh model; `validate_time01_selection` independently recomputes physical loads and Budget. `temporal_pricing_bound` includes signed segment prices from Budget duals. Its bounded-hop walk relaxation gives a conservative global lower bound; invalid repeated-segment walks are never installed as routes. Restricted-pool MIP bounds certify the full problem only when enumeration is complete. Achieving MLU gap 10% does not end the search or certify the entire vector.

## Verification and execution

`test/time01.jl` verifies directed failures, data indexing, Budget, accepted vertex revisits, both official-toy reference vectors (Budget 0 and 20), and a conservative pricing bound. The independent rational oracle is `scripts/audit_time01_reference.py`; these computed optima are not published SetA optimal solutions. All 20 original SetA time-1 data loaders additionally passed 120 assertions locally.

Open `Project_Orange.jl` in Pluto for visible Data and short toy results. Merely opening the notebook does not launch SetA experiments.

For a deliberately short local pilot, from the project directory:

```sh
julia --project=. scripts/run_time01_experiments.jl --instances 1 --runs 1 --time-limit 10 --solver highs --threads 1 --output results/local_time01_10s
```

The time limit counts only the sum of `optimize!` calls. Loading, compilation, route generation and model construction add wall time. Check the result's `validated`, `budget_used ≤ budget`, global `gap`, `lex_completed_stages`, `lex_total_stages`, pool completeness and termination. “Optimal” requires the entire vector to be certified within the reported numerical tolerances. A good feasible MLU alone is insufficient.

The full extended experiment defaults to 3600 seconds and ten repetitions; do not run the default CLI during validation. Resume requires identical configuration and only skips completed runs; a checkpoint does not restore a solver tree. Private worker copies are required because notebook demonstration outputs otherwise share filenames. Linux resource monitoring still needs validation before cloud deployment.

For a reproducible independent audit without SetA optimization:

```sh
julia --project=. scripts/audit_time01_reference.jl
```

This requires Python 3 (standard library only). If an official compiled checker is available, set `ORANGE_CHECKER` to its absolute path to additionally verify exported routes, Budget and every physical load. The audit also compares all 2,156 reachable-pair/arc/time ECMP coefficients against exact rational calculations.

## Additional guarded local capacity checks

Two independent process runs were performed sequentially, each configured for only 5 optimize seconds, with an external 8-GiB RSS guard and 120-second whole-process wall guard. Neither guard fired. A short independent fixture audit briefly overlapped the first process; these measurements are resource checks, not controlled CPU-speed comparisons. Every resulting load and Budget was checked by the official checker (maximum discrepancy about 1e-12).

| Instance | Actual optimize seconds | Algorithm wall seconds | Whole-process seconds | Native peak RSS GiB | Budget | Certified prefix | Global MLU gap |
|---|---:|---:|---:|---:|---|---|---:|
| SetA-09 | 5.0170 | 16.0189 | 32.37 | 1.215 | 18/18 | 3/1500 | 0.00004354% |
| SetA-20 | 5.6882 | 25.0987 | 78.91 | 1.521 | 0/90 | 0/4000 | 100.00000000% |

SetA-20 retained the initial feasible direct-routing solution: MLU 0.999999333333, Budget 0/90. The short run established no positive global lower bound and certified no lexicographic stage. A 100% reported bound gap reflects that missing bound, not a proof that the feasible solution is 100% worse than optimal. The 5-second setting took 5.6882 seconds inside optimize calls; native solver interruption is not an exact hard real-time deadline. The external process guard is separate.

These results establish successful data/model allocation and feasible routing for representative original instances. They do **not** establish long-run memory bounds, the requested 10% MLU quality on large instances, or guaranteed completion within 28 hours. Do not provision the full cloud plan based on this smoke test.

The explicit `1:1` CLI selection and identical-config resume were also exercised with a one-second workflow check. Resume returned the completed row without a second solve. Pluto executed all 203 cells without errors. The reproducible rational audit passed 36 data/model assertions and all 2,156 coefficient comparisons; optional official-checker assertions passed as well.

## Paired-demand master–pricing (current default)

`solve_time01` now defaults to `formulation=:paired`. The earlier formulation is retained as `solve_time01_separate` or `formulation=:separate` for regression comparison. Earlier 44/44 official-toy figures in this guide refer to the exhaustive separate-column reference; they must not be presented as the performance of the new short root-pricing search.

A column contains both routes of one demand. It stores the two physical load vectors and the exact symmetric-difference Budget cost. The master has one choice equality per demand, one global Budget row, physical-load rows and the same joint top-k objective/locks. No physical capacity ceiling of 1 is introduced: loads may exceed 1 under the original congestion-minimization model.

Pricing solves a demand-specific MILP in a graph with K layers for each period. A target waiting edge pads paths shorter than K; real segments are usable at most once, with vertex revisits allowed. Continuous XOR variables compute the exact transition cost. The objective combines current load dual costs with the Budget dual price. The pricing master does not fix time 0, change volumes, relax MaxSeg or assign a permanent Budget quota to any demand.

A validated pricing incumbent can add a pair. Its objective is **not** a lower bound on the pricing minimum. Global bounds use only native pricing lower bounds and conservative analytical floors, with a safety buffer. If the initial LP dual objective is D_R and alpha_d are demand duals, the missing-column correction is D_R + sum_d min(0, lower_price_d - alpha_d). A floor permits a valid but weak bound when a demand is not priced before the time limit or its model exceeds the allocation guard. Diversification pricing excludes stored pair incidences and generates alternatives useful for integer search; its bounds are excluded from the global correction.

All native optimize calls count: master LP + demand pricing (including diversification) + restricted master MIP. `nodes` counts restricted master MIP nodes; `pricing_nodes` counts demand-subproblem nodes; `total_nodes` is their sum. `*_cycles.csv` records stage/global bound/certification and time breakdown. `*_cycles_pricing.csv` records demand index and original demand ID, pricing status, candidate reduced cost, added column and pricing lower bound. A diversification row deliberately has no global pricing lower bound.

This is root column generation with repeated restricted MIP solves. It is **not branch-and-price**. LP optimality or a restricted-pool integer optimum can leave a positive full integer gap. The search does not stop upon attaining 10% MLU gap and never advances an uncertified lexicographic stage. A short run can remain Not Optimal while providing a valid solution and globally meaningful MLU bound.

Reproduce the bounded fixture audit:

```sh
julia --project=. scripts/audit_time01_pairs.jl
```

Optional: set `ORANGE_CHECKER` to an existing official checker executable to verify exported JSONs, Budget and all loads independently. The audit enumerates all admissible ordered-segment sequences for tiny pricing oracles, exercises Budgets 0/3/20 and signed dual costs, checks full-domain bound correction and paired/separate LP ordering, then runs only short toy searches. A MaxSeg=1 toy variant checks complete lexicographic certification in a singleton route domain; it is a unit fixture, not a replacement SetA dataset.

For a deliberately short original-instance workflow check:

```sh
julia --project=. scripts/run_time01_experiments.jl --instances 1 --runs 1 --time-limit 1 --solver highs --formulation paired --threads 1 --output results/time01_paired_cli
```

`--pricing-slice` caps an individual pricing optimize call; the shared remaining budget can reduce it further. `--max-pricing-variables` guards each pricing MILP, while `--max-variables` guards masters and caps pricing as well. Resume schema 3 records formulation and pricing settings and rejects older/different configurations. These knobs bound computation, not the original feasible set: a guarded or timed-out pricing demand remains uncertified. No long run or cloud deployment is authorized by these examples. Earlier cloud scheduling estimates require remeasurement for this implementation.

## Paired-demand local observations (2026-10-21)

The bounded paired audit passed 89 assertions; the combined time-1 regression added 36 reference assertions (125 total). Pricing MILPs matched independent exhaustive enumeration for Budgets 0, 3 and 20, including signed-cost reconstruction. The test of paired versus separate LP relaxation and the test of exclusion-pricing semantics passed. The MaxSeg=1 singleton unit fixture certified 44/44 ranks. The original MaxSeg=4 toy searches below were limited to two optimize seconds each; they are not full-vector certificates.

| Toy Budget | MLU | Global MLU bound | Budget used | Certified prefix | Pair columns | Pricing calls | Optimize seconds | Algorithm wall seconds |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| 20 | 0.375000 | 0.374999735 | 0 | 8/44 | 45 | 102 | 1.9992 | 3.3863 |
| 0 | 0.375000 | 0.374999735 | 0 | 8/44 | 26 | 64 | 1.9995 | 2.6562 |

The official checker accepted both exported solutions and agreed with the recomputed Budget and every load to within 1e-9 (the checker's output precision). Both runs correctly ended TIME_LIMIT / Not Optimal. The MLU bound is tight numerically, but the short search has not completed the lexicographic vector. This does not establish a speedup over the exhaustive reference implementation.

A separate one-second SetA-01 CLI workflow check returned a checker-valid incumbent, Budget 0/51, and exercised 47 demand pricing calls. It did not certify a lexicographic stage. Identical-config resume reused the completed row. No longer original-instance experiment or cloud resource was started. Pluto executed 226 cells without errors after adding the decomposition section.
