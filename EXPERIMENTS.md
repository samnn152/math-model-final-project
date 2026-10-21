# Time-0 experiments

The executable implementation and mathematical explanation live in `Project_Orange.jl`; the CLI includes that notebook without launching Pluto. HiGHS and next-hop ECMP are defaults. See [HIGHS_OPTIMIZATION.md](HIGHS_OPTIMIZATION.md) for the equivalent route formulation and global-bound derivation.

## Objective and quality

Sort physical normalized loads decreasingly. Stage k minimizes their top-k sum, locking only previously certified stages. This implements the original lexicographic objective. MLU is stage 1, not the entire objective.

A validated feasible solution U and valid global MLU lower bound L give gap = 1 - L/U. The requested target is gap ≤ 0.10. Zero objectives are handled separately; missing solutions or bounds produce missing gaps rather than invented values.

The route pool is restricted. Its native integer bound cannot generally certify the original problem. Full-domain LP pricing supplies a global bound; the original objective and constraints remain displayed in Pluto. Numerical proof tolerance is absolute 1e-7 by default. A 10% approximate stage is never locked as optimal.

## Short trial

```sh
julia --project=. scripts/run_experiments.jl --instances 4 --runs 1 --time-limit 60 --solver highs --splitting ecmp --target-gap 0.10 --output results/trial_highs_ecmp
```

For external deadline and memory supervision of one instance on macOS:

```sh
python3 scripts/run_guarded_highs.py --instance 4 --time-limit 60 --target-gap 0.10 --output results/trial_highs_guarded
```

The guarded directory must be new. Its `guarded_result.json` records normal or externally interrupted outcomes; its `experiment/` subdirectory contains normal runner artifacts. The supervisor uses one solver thread and defaults to a 12-GiB sampled RSS ceiling. Memory sampling is not an OS reservation or an exact continuous peak measurement.

## Coursework batch settings

The assignment requests all 20 SetA instances at time 0, a 1800-second optimize budget per run, and ten repetitions for averages. It does not require both solvers. This command is provided for later use; the full batch has **not** been launched:

```sh
julia --project=. scripts/run_experiments.jl --instances 1:20 --runs 10 --time-limit 1800 --solver highs --splitting ecmp --target-gap 0.10 --output results/time0_highs_ecmp
```

This direct batch does not use the external supervisor. Native time limits and cooperative callbacks can overrun slightly. For process isolation, use the guarded runner one instance at a time; it currently runs one repetition per invocation. Do not confuse those individual pilots with the ten-repeat experiment.

If every run uses its full budget, 20 × 10 × 1800 seconds is 100 hours of optimize time, plus overhead. This is a budget calculation, not a runtime or optimality guarantee. No parallel batch is enabled automatically.

## Settings

- `--solver highs` or `scip`; use separate output directories.
- `--formulation auto` selects compact for at most 100,000 potential segment binaries, routes otherwise. Explicit `compact`/`routes` are available.
- `--highs-profile auto` selects incumbent-oriented search for compact HiGHS and defaults for route masters. Explicit profiles: `default`, `incumbent`, `devex`, `lean`.
- `--target-gap 0.10` is the MLU reporting target, not a loose solver stopping gap.
- `--max-routes 16`, `--pricing-rounds 40`, `--pricing-time 30`, and `--warm-start-seconds 3` set the initial pool cap, per-call LP rounds and pricing allowance, and initial heuristic allowance. The pool cap grows on retries while the global variable guard remains active. More search gives no guarantee.
- `--threads 1` is the controlled default. Model size guards reject allocation before an oversized selected formulation is built.
- `--splitting ecmp` matches the subject; `uniform_paths` is the alternative handout convention. Never pool their averages.

Run `julia --project=. scripts/run_experiments.jl --help` for all flags. Reusing a normal runner output directory resumes completed runs only when its recorded settings match. Different settings or earlier schema versions require a new directory. Guarded output directories are deliberately not reused.

## Continued route search

The solver retries an unfinished lexicographic stage, keeping its incumbent and strongest global bound. Between solves it enumerates additional valid simple waypoint routes, grows the initial per-demand pool allowance, and reruns LP pricing. Restricted integer solves use slices of at most 60 seconds. Reaching the 10% MLU reporting target does not stop the run. No stage is advanced without global certification.

Pure route work is outside the optimize budget. An additional search-wall safeguard is checked between cycles at budget + max(30 seconds, 10% of budget); the process supervisor has its own deadline/memory safeguards. Stop reasons distinguish these conditions from optimality. Stage CSV rows now include `cycle`, `added_enumerated_routes` and `pool_limit`; native filenames include both stage and cycle. Current result directories use schema 5 and cannot resume older-policy runs.

## Files and columns

`config.json` (schema 5) records run settings. `environment.json` records software/hardware. Each completed run writes a JSON row; `runs.csv` and summary tables collect those rows. Route and load validation is performed independently before accepting a solution.

| Field | Meaning |
|---|---|
| `vertices`, `links`, `demands` | Number of routers, directed physical arcs, and demands |
| `objective`, `checked_mlu` | Best feasible MLU; the latter is independently recomputed |
| `lower_bound`, `gap` | Global MLU bound and relative gap |
| `cpu_time_seconds` | Elapsed wall time inside optimize calls only, summed across LP/MIP and stages; retained assignment column name, not OS CPU utilization |
| `wall_time_seconds` | Solve routine elapsed wall time including its route/pricing/validation overhead; excludes earlier loading/startup |
| `status` | Optimal for the full vector, Not Optimal otherwise, or Infeasible only with a valid original-problem proof |
| `termination` | Stop reason, e.g. TIME_LIMIT, SEARCH_WALL_LIMIT or ROUTE_POOL_LIMIT |
| `validated`, `feasible` | Independent validation and incumbent availability |
| `mlu_target_met`, `quality_status` | Whether the requested global MLU threshold is certified |
| `lex_completed_stages`, `lex_total_stages` | Certified prefix length and physical arc count |
| `active_stage`, `stage_objective`, `stage_lower_bound`, `stage_gap` | Current top-k stage and its global certificate |
| `sorted_loads_json` | Actual decreasing physical-load vector |
| `binary_variables`, `candidate_routes` | Allocated binary/route count; diagnostics depend on formulation |
| `nodes` | Native search-node statistic; route LP work and separate stages require their own logs |
| `solver`, `solver_version`, `splitting`, `formulation` | Configuration needed to interpret and compare results |

Additional diagnostics include pricing, heuristic, callback and formulation-specific measurements; unavailable values are missing. Check the per-stage CSV for bounds and completed stages. `*_pricing.csv` records pricing progress and global LP bounds. Native `*_stage-*.log` files contain solver messages; a restricted-master native optimal status is not by itself an original-problem certificate.

`*_solution.json` is atomically checkpointed with validated routes, loads and saved global bounds. An external stop can preserve this earlier incumbent, but cannot recover unsaved solver progress. `*.event.json` informs the supervisor of optimize-call boundaries. `guarded_result.json` adds stop reason, sampled process-tree RSS and supervisor wall time; unfinished optimize timing may be missing.

Quality labels are `LEX_OPTIMAL`, `MLU_TARGET_MET_LEX_INCOMPLETE`, `TARGET_NOT_MET`, or `NO_FEASIBLE_SOLUTION`. Only full certification makes `status=Optimal`. For the report retain individual seeds/results, average executed runs, and distinguish missing/error/size-limited rows from solved runs. Do not average MLU-target success into a claim of lexicographic optimality.


## Observed 1800-second continued-search pilot

SetA-04 (HiGHS 1.15.1, ECMP, one thread, seed 1001) completed with `TIME_LIMIT` and `Not Optimal`: MLU **0.4591193467336683**, global bound **0.4590677738489471**, gap **0.011233001852%**, certified prefix **0/250**. It completed 150 search cycles, expanding from 398 to 59,998 route columns, rather than stopping at the 10% reporting threshold.

Optimize calls totaled **1800.012875 seconds**; the solve routine took **1936.823670 seconds**, and the supervisor including startup took **1951.270954 seconds**. The small native overrun is recorded rather than rounded away. Peak sampled RSS was **2.171 GiB after supervisor handoff only**, not a full-run peak. The in-place supervisor handoff preserved the running Julia solve and allowed model/route overhead; no external timeout ended this run.

Independent Python reconstruction from the original JSONs verified all 200 routes and matched every stored physical load exactly in this run. Cycle-level incumbent/bound monotonicity and optimize-time sums also passed. The MLU target is met; the full lexicographic objective remains uncertified. The last MLU improvement occurred at cycle 7, so extra search did not guarantee further progress.

See [HIGHS_OPTIMIZATION.md](HIGHS_OPTIMIZATION.md) for the full table and local artifact paths. SetA-09 was subsequently stopped at the user's request; its preserved checkpoint is marked USER_INTERRUPTED. No full batch was started, and this follow-up automation is now paused.

## Joint time-0/time-1 extension: local tests first

The new notebook section constructs `G(1)`, recomputes ECMP and traffic, and solves both periods with the original segment-set Budget and a joint lexicographic objective. See [docs/TIME01.md](docs/TIME01.md) for equations, function roles and the explicit short-pilot command. `scripts/run_time01_experiments.jl` is the separate extended runner; its default 3600-second / ten-run batch has not been launched.

Local verification on 2026-10-21: 120 assertions passed across all 20 original time-1 data loaders. The official toy at Budget 20 and 0 reached 44/44 certified stages and matched independent rational optimal vectors. The official checker accepted both and reproduced all loads to less than 1e-12. A single SetA-01 joint pilot used 10.0079 optimize seconds and 10.7018 algorithm wall seconds: MLU 0.929383899821, global bound 0.929383513944, relative MLU gap 4.15196e-7 (0.00004152%), Budget 23/51, 230 nodes, 2017 route columns, and 1/160 certified stages. It ended TIME_LIMIT / Not Optimal; the full vector remains uncertified. Official checker accepted it and agreed on every load to less than 1e-12. Whole process took 32.41 seconds including startup/compilation/toy solves, with peak RSS 1,093,730,304 bytes and peak footprint 1,006,274,072 bytes. These are short small-instance measurements.

No cloud resources have been provisioned. The candidate configurations in [docs/gcp-experiment-plan.json](docs/gcp-experiment-plan.json) remain conditional on representative larger local memory tests, Linux monitoring, actual quota and a cloud pilot. Full Steps 6 and 9 together have a 300-hour aggregate optimize allowance; four workers do not meet a 28-hour schedule.

## Additional guarded local capacity checks

Two independent process runs were performed sequentially, each configured for only 5 optimize seconds, with an external 8-GiB RSS guard and 120-second whole-process wall guard. Neither guard fired. A short independent fixture audit briefly overlapped the first process; these measurements are resource checks, not controlled CPU-speed comparisons. Every resulting load and Budget was checked by the official checker (maximum discrepancy about 1e-12).

| Instance | Actual optimize seconds | Algorithm wall seconds | Whole-process seconds | Native peak RSS GiB | Budget | Certified prefix | Global MLU gap |
|---|---:|---:|---:|---:|---|---|---:|
| SetA-09 | 5.0170 | 16.0189 | 32.37 | 1.215 | 18/18 | 3/1500 | 0.00004354% |
| SetA-20 | 5.6882 | 25.0987 | 78.91 | 1.521 | 0/90 | 0/4000 | 100.00000000% |

SetA-20 retained the initial feasible direct-routing solution: MLU 0.999999333333, Budget 0/90. The short run established no positive global lower bound and certified no lexicographic stage. A 100% reported bound gap reflects that missing bound, not a proof that the feasible solution is 100% worse than optimal. The 5-second setting took 5.6882 seconds inside optimize calls; native solver interruption is not an exact hard real-time deadline. The external process guard is separate.

These results establish successful data/model allocation and feasible routing for representative original instances. They do **not** establish long-run memory bounds, the requested 10% MLU quality on large instances, or guaranteed completion within 28 hours. Do not provision the full cloud plan based on this smoke test.

## Paired-demand decomposition

The two-period default now selects route pairs per demand and generates further columns using demand-specific pricing MILPs. Shared optimize time includes all pricing calls, not just the final integer master. Run schema 3 records formulation and pricing allocation settings; old checkpoints are not silently reused. Stage and demand pricing CSVs distinguish globally valid corrected bounds from restricted integer/diversification bounds. The implementation is not branch-and-price and does not certify full integer optimality from a restricted master alone. See [TIME01.md](docs/TIME01.md).

## Paired-demand local observations (2026-10-21)

The bounded paired audit passed 89 assertions; the combined time-1 regression added 36 reference assertions (125 total). Pricing MILPs matched independent exhaustive enumeration for Budgets 0, 3 and 20, including signed-cost reconstruction. The test of paired versus separate LP relaxation and the test of exclusion-pricing semantics passed. The MaxSeg=1 singleton unit fixture certified 44/44 ranks. The original MaxSeg=4 toy searches below were limited to two optimize seconds each; they are not full-vector certificates.

| Toy Budget | MLU | Global MLU bound | Budget used | Certified prefix | Pair columns | Pricing calls | Optimize seconds | Algorithm wall seconds |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| 20 | 0.375000 | 0.374999735 | 0 | 8/44 | 45 | 102 | 1.9992 | 3.3863 |
| 0 | 0.375000 | 0.374999735 | 0 | 8/44 | 26 | 64 | 1.9995 | 2.6562 |

The official checker accepted both exported solutions and agreed with the recomputed Budget and every load to within 1e-9 (the checker's output precision). Both runs correctly ended TIME_LIMIT / Not Optimal. The MLU bound is tight numerically, but the short search has not completed the lexicographic vector. This does not establish a speedup over the exhaustive reference implementation.

A separate one-second SetA-01 CLI workflow check returned a checker-valid incumbent, Budget 0/51, and exercised 47 demand pricing calls. It did not certify a lexicographic stage. Identical-config resume reused the completed row. No longer original-instance experiment or cloud resource was started. Pluto executed 226 cells without errors after adding the decomposition section.
