# HiGHS implementation and measured pilots

## 24 October: experimental full-domain integer certificates

The local route/certificate investigation is documented in
[the verification report](reports/route_certificate_local_20261024/README.md).
It adds generated complete routes and an adaptive integer lower-bound model,
including a guarded sparse physical-flow relaxation for deterministic routing.
HiGHS remains the batch default; SCIP is being tested as the local certificate
backend for difficult ranks. No full-vector Optimal claim or cloud deployment
follows from MLU gap zero. These diagnostic results are separate from experimental
repetitions and do not modify the general Budget model.

The reporting target is a validated solution with **MLU gap ≤ 10%**, while retaining the original decreasing-load lexicographic objective. This target does not stop later-rank optimization or certify the full vector. The notebook also implements the joint time-0–1 model with Budget; individual certificate reductions have the narrower scope stated below.

## Original model and equivalent route representation

`Project_Orange.jl` retains the original segment variables, flow conservation, segment limit, physical-load equations, and sequential lexicographic objectives in its mathematical section and compact implementation.

For demand d, let P_d contain all simple waypoint routes from its source to its destination using at most K = MaxSeg segments. For route p, define

    q[a,d,p] = v[d,0] / c[a] * Σ_(i,j in p) r[i,j,a,0].

An equivalent full route model selects exactly one route per demand:

    Σ_(p in P_d) y[d,p] = 1,     y[d,p] ∈ {0,1},
    load[a] = Σ_d Σ_(p in P_d) q[a,d,p] y[d,p].

At time 0, deleting a waypoint cycle removes nonnegative traffic contributions and uses fewer segments. Therefore a simple-route optimum exists. This equivalence is specific to the implemented time-0 problem; it is not a proof for the later reconfiguration-budget model.

With m physical arcs and decreasing loads load_(1) ≥ ... ≥ load_(m), minimize in sequence

    F_k = Σ_(j=1..k) load_(j),    k = 1,...,m,

locking only previously certified optimal values, within documented numerical tolerances. The standard top-k epigraph uses F_k = min_theta k*theta + Σ_a max(load[a]-theta,0). F_1 is MLU. Full lexicographic optimality requires all m stages.

## Why memory falls

The compact formulation allocates one segment binary for every demand and reachable ordered router pair, potentially O(D n²). The route formulation allocates binaries only for its generated route pool. It retains the same sparse routing data and physical-load constraints.

`formulation=:auto` selects compact up to 100,000 potential segment binaries, and route columns above that threshold. `:compact` and `:routes` can be requested explicitly. A bounded greedy search adds feasible direct/two-segment alternatives and improves the initial sorted-load vector. It does not change or fix any original constraint.

The generated pool is a **restricted** model. Its best integer solution is a feasible upper bound for the original problem. Its native MIP lower bound is generally not a global bound. No restricted-pool optimality claim is promoted to original-problem optimality unless the pool is independently verified complete.

## Global bounds from pricing

The LP master supplies demand-equality duals alpha[d] and nonnegative physical-load prices w[a]. Dynamic programming computes the minimum route cost over **all** routes of at most K segments, not just the pool:

    cost(i,j) = Σ_a w[a] r[i,j,a,0] / c[a],
    rho[d] = v[d,0] * minimum_route_cost[d] - alpha[d].

If D_R is the restricted LP dual objective, adjusting each equality dual downward by min(0,rho[d]) yields the global lower bound

    L = D_R + Σ_d min(0,rho[d]).

The implementation subtracts numerical safety buffers, including a correction for projecting tiny negative load duals to zero. Only completed full-demand pricing sweeps contribute bounds. A source/sink cut also supplies a global MLU bound. Pricing can add improving routes and repeat. Round caps apply to each LP-pricing call; the initial per-demand pool cap grows when a stage is retried. Neither cap changes the scope of a bound established by complete pricing.

This is restricted integer optimization with LP pricing, **not full branch-and-price**. LP integrality gaps or omitted useful integer columns may prevent certification. The current implementation retries the same unfinished stage until its budget or an explicit resource safeguard is reached. It no longer stops with `GLOBAL_GAP_REMAINS`. More search does not guarantee a better solution.

For a feasible incumbent U > 0 and a valid global lower bound L:

    gap_MLU = 1 - L / U.

`mlu_target_met=true` requires this gap ≤ 0.10. A stage advances only when its global upper/lower difference is within the proof tolerance (default absolute 1e-7). The 10% target never becomes a lexicographic lock tolerance. No approximate stage is treated as optimal.

## Continued search policy

If a stage remains uncertified, keep its best feasible incumbent and strongest global lower bound, expand the pool, rerun pricing and solve another restricted MIP. A persistent cursor enumerates simple waypoint sequences in increasing segment count, adding a bounded batch per demand. This also introduces routes with nonnegative LP reduced cost, which can help integer solutions even when LP column generation has converged. The initial per-demand cap grows on retries; the global allocation guard remains active.

Each restricted MIP receives at most 60 seconds, preserving opportunities to generate additional routes. Only certification advances the lexicographic stage; the 10% MLU target never controls search termination. All earlier locks remain in every LP/MIP master. Checkpoints are refreshed after each cycle, and native logs have separate stage and cycle numbers.

The solve budget still counts optimize calls only. An additional search-wall safeguard checks for elapsed wall time exceeding that budget plus max(30 seconds, 10% of the budget) between cycles. Resource/wall interruptions are reported explicitly. Route enumeration is exponential in the worst case; this policy does not turn the restricted search into full branch-and-price or guarantee certification.

## Earlier 60-second pilots: 21 October 2026

Apple M4, 24 GiB RAM, Julia 1.13.1, native HiGHS 1.15.1, one thread, time 0, next-hop ECMP. One run each with a 60-second total optimize-call budget. These are pilots, not ten-run coursework averages.

| Instance | Potential compact binaries | Route binaries | MLU | Global MLU gap | Certified lex stages | Optimize calls (s) | Algorithm wall (s) |
|---|---:|---:|---:|---:|---:|---:|---:|
| SetA-04 | 490,000 | 398 | 0.462788191 | 0.803914% | 0/250 | 0.007591 | 0.324 |
| SetA-09 | 4,470,000 | 466 | 0.537626396 | 5.997141% | 0/750 | 0.012856 | 1.912 |
| SetA-20 | 957,600,000 | 6,276 | 0.991312385 | 0.000004018% | 2/2000 | 60.034044 | 64.615 |

These historical pilots used the preceding early-stop policy. All three solutions passed independent route/load validation and met the requested MLU threshold. All remain **Not Optimal** for the complete lexicographic vector. SetA-04 and 09 stopped with `GLOBAL_GAP_REMAINS`; SetA-20 reached its time budget during stage 3. Its stage-3 gap was about 0.002955%, which still does not certify that stage.

Peak native memory footprint for the entire process running these three instances sequentially was **1,071,908,448 bytes, about 1.00 GiB**. This includes startup and data; it is not a separate per-instance peak. It does not establish the safety of multiple concurrent jobs. Raw logs, CSV and resource output are in `results/highs_ecmp_routes_20261021/` locally (results are ignored by Git).

Older performance reports used the uniform-complete-shortest-path convention and the compact model. They are historical; these numbers are not a controlled speed comparison with those runs. The current ECMP convention matches the original subject. The alternative remains available explicitly.

## Continued-search pilot: SetA-04, 1800-second budget

Completed on 21 October 2026 with the same native HiGHS 1.15.1, one thread, ECMP and original time-0 lexicographic objective. One run only, seed 1001; this is not a ten-run average.

| Measurement | Result |
|---|---:|
| Vertices / directed links / demands | 50 / 250 / 200 |
| Best validated MLU | 0.4591193467336683 |
| Global MLU lower bound | 0.4590677738489471 |
| Global MLU gap | 0.011233001852% |
| Certified lexicographic prefix | 0/250; active stage 1 |
| Status / termination | Not Optimal / TIME_LIMIT |
| Sum of optimize-call wall time | 1800.012875 s |
| LP / restricted MIP optimize time | 157.702514 / 1642.310362 s |
| Solve routine wall time | 1936.823670 s (32 min 16.824 s) |
| Supervisor wall time including startup | 1951.270954 s (32 min 31.271 s) |
| Search cycles / initial route columns / final route columns | 150 / 398 / 59,998 |
| Added enumeration columns | 59,600 |
| Sum of restricted-MIP node counts | 22,037 |
| Peak sampled process-tree RSS after supervisor handoff only | 2.171 GiB |

The search did not stop at the 10% MLU target: it performed 150 cycles and consumed the full optimize budget. Its initial restricted solution had MLU 0.46278819095477386 and gap 0.803914%; the final MLU improved by about 0.792770% and its global gap fell to 0.011233%. The last strict MLU improvement occurred at cycle 7. Subsequent search did not improve the incumbent or close the global certificate. A restricted integer solve can be optimal while the original problem remains uncertified, so no later lexicographic stage was unlocked.

A separate Python audit rebuilt shortest-path ECMP from the three original JSON files, using exact rational metric comparisons. It checked all 200 selected routes, their endpoint/MaxSeg/simplicity requirements and every physical load, matching stored loads with maximum absolute error 0. It also checked monotonic bounds/incumbents across cycles and summed timing against the final run row. These checks validate the incumbent and bookkeeping; the global bound comes from the pricing construction described above.

Local artifacts: `results/highs_continued_1800_20261021/setA-04/guarded_result.json`, `experiment/setA-04_run-01_stages.csv`, native cycle/pricing logs, the solution JSON and `experiment/audit.json`. The parent directory retains the notebook snapshot and its SHA-256 in `pilot_config.json`.

The supervisor was handed over in place during the run to include route/model overhead in its external deadline. The Julia solve was not restarted; the final stop was its native budget, not an external kill. The RSS measurement covers only the period after that handoff and is not a full-run memory peak. The current standard supervisor allows setup + solve budget + max(30 seconds, 10% of solve budget) + grace for its overall deadline; optimize-call accounting still excludes setup and route work. The 0.012875-second native overrun reflects cooperative time-limit enforcement.

SetA-09 was subsequently stopped at the user's request; its saved checkpoint is marked USER_INTERRUPTED. Its incomplete outcome is not included in the completed-pilot table. The requested one-time follow-up was disabled after this SetA-04 audit; no full batch or duplicate job was launched.

## Run one guarded job

From the repository root on macOS:

```sh
python3 scripts/run_guarded_highs.py --instance 20 --time-limit 1800 --target-gap 0.10 --output results/highs_ecmp_20_guarded
```

Choose a new output directory. The supervisor launches one Julia process, uses one solver thread, watches memory, and preserves validated checkpoints. Default sampled RSS ceiling is 12 GiB; this is a termination threshold, not an OS memory reservation. Close unnecessary applications and prevent sleep for a long run.

The budget counts LP and MIP `optimize!` calls across all lexicographic stages. Data loading, compilation, route pricing, warm starts, validation and file writing are extra wall time. A native callback requests interruption at the remaining solve budget. Since callbacks are cooperative, the supervisor adds an external deadline with setup allowance and grace. External stops are reported explicitly, never as optimal; unfinished optimize-call time may be missing.

Read `guarded_result.json` first, then `experiment/runs.csv`, the per-run solution/checkpoint JSON and stage/pricing logs. An actual small guarded run and a synthetic forced-timeout/checkpoint-preservation test passed. The synthetic test is infrastructure validation, not a numerical optimization result.

For an unguarded pilot with normal resumable batch files:

```sh
julia --project=. scripts/run_experiments.jl --instances 4,9,20 --runs 1 --time-limit 60 --solver highs --splitting ecmp --target-gap 0.10 --output results/highs_ecmp_pilot_new
```

Profiles `default`, `incumbent`, `devex`, and `lean` are selectable with `--highs-profile`. `auto` uses the incumbent-search profile for compact HiGHS models and native defaults for route masters. Profile changes affect search, not the mathematical problem.

No full SetA batch was launched for this update. See [EXPERIMENTS.md](EXPERIMENTS.md) for report fields and full-batch settings.


## Reference validation and known limitations

See [REFERENCE_AUDIT.md](REFERENCE_AUDIT.md). Both current HiGHS formulations exactly match all 22 entries of an independently exhaustive optimum on the official subject's example. The official checker also accepts the saved SetA-04 solution, but does not prove it optimal. An unmodified compact SCIP run fails at stage 11 due to repeated partial warm-start storage; the audit localizes this integration failure without changing the production notebook. No additional long experiment was run.

## Joint two-period decomposition

Time 0 alone retains the preceding implementation. For periods 0 and 1, `solve_time01` now defaults to paired-demand master–pricing, with exact Budget coefficients and demand-specific hop-indexed pricing MILPs. Master LP, pricing and master MIP optimize times share the same total budget. Native restricted MIP bounds are not global integer certificates; conservative corrected LP bounds govern lexicographic advancement. See `docs/TIME01.md` for equations, logs, regression results and the remaining root-only integrality limitation.

## Paired-search stagnation and native memory cleanup (23 October)

Revision `stall_memory_v1` removes repeated unchanged-pool master rebuilds, tightens the existing walk bound at actual traffic ratios, enables unrestricted/excluded demand pricing on stalled dynamic searches, and immediately finalizes disposable HiGHS instances. Original Budget, admissible routes, integrality and lexicographic objectives are unchanged. A warm-started bounded SetA-05 local check peaked at 1.6409 GiB and retained its valid MLU and first-stage certificate; 400 disposable SetA-05 masters stayed near 1.069 GiB. See [evidence and rollout limits](reports/paired_stall_memory_fix_20261023/README.md). This is not a proof of a universal memory cap or full lexicographic convergence.

### Optimize-call budget policy, 24 October

`experiment_wall_deadline` returns infinity by default. Route-based time0, paired time0–1 and the separate reference no longer stop at an implicit wall multiple of the solver-call budget. Explicit diagnostic wall guards still report SEARCH_WALL_LIMIT. Gap MLU zero does not stop subsequent lexicographic stages. See `reports/optimize_budget_policy_20261024/README.md` for exact local results: nontrivial time0 reaches 4/4; paired original toy reaches only 8/44 within 30 optimize seconds; the existing full-enumeration temporal reference reaches 44/44. The latter is a reference verification, not a replacement production algorithm or a certificate for the paired run.

The new 200-run Step6 cohort has separate IDs, claims and output directories and uses the corrected notebook. Four 50-job shards were prepared; the cross-dispatcher gate limits each VM to four actual Julia processes while preserving the 11 existing Step9 PIDs. An initial dispatcher-signature mismatch failed before Julia launch; the caller was corrected to support the deployed mandatory stop event, and only those pre-launch failures can be reclaimed with CAS. Audit after correction: 16 actual workers = 11 old Step9 + 5 new Step6; 200 unique new assignments, no duplicate actual job IDs. Existing Step9 private notebooks remain on their loaded execution policy, so they may still stop at the legacy internal wall guard. Hourly reports now label the new Step6 cohort separately from old completion totals.
