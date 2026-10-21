# Pinned HiGHS one-pass SetA plan — not started

The project owner confirmed that Step 9 means periods 0 and 1 jointly with Budget, despite the original assignment's repeated time-0 wording. This plan uses all 20 original SetA instances once per experiment. It is preliminary data, not the ten-repetition average requested for the final report.

| Setting | Step 6 | Step 9 |
|---|---|---|
| Periods | 0 | 0 and 1 jointly |
| Formulation | route columns | paired-demand master–pricing |
| Budget | none | original scenario Budget |
| Shared optimize-call allowance per instance | 1800 seconds | 3600 seconds |
| Runs / instance | 1 | 1 |
| Solver | HiGHS, one thread, default native search profile | HiGHS, one thread, default native search profile |
| Seed | 1001 | 1001 |
| Routing | next-hop ECMP | next-hop ECMP |
| Lexicographic lock tolerance | 1e-7 | 1e-7 |
| Stage proof tolerance | 1e-7 | 2e-6 |

Native relative MIP gap remains zero. The 10% MLU target is reporting metadata; it does not stop search. Stage certificates use the documented absolute numerical tolerances. The experiment formulations differ because Step 9 includes temporal coupling; do not attribute all performance differences exclusively to Budget.

The script pins Julia/BLAS/OpenMP thread counts, runs Step 6 then Step 9 sequentially, and appends console logs. It records SHA-256 hashes of notebook, project/manifest and CLI sources and rejects resume after those sources change. Existing completed run JSONs are reused only with identical runner configuration. Checkpoints preserve validated partial solutions, not solver trees; interruption can require restarting the unfinished instance. Including the notebook executes only its short demonstrations before the selected batch.

## Manual launch on macOS

From the repository root:

```sh
caffeinate -i bash scripts/run_seta_one_pass_highs.sh all
```

For separate launches, in this order, using the same directory:

```sh
caffeinate -i bash scripts/run_seta_one_pass_highs.sh 6
caffeinate -i bash scripts/run_seta_one_pass_highs.sh 9
```

Run the same command to resume. These commands have been prepared, not executed. Keep the Mac powered and the terminal session open; caffeinate inhibits idle sleep but does not detach the job or prevent lid-close sleep. Do not launch these commands simultaneously from a shared checkout.

## Files

The fixed output root is `results/seta_one_pass_highs_20261021/`:

- `source-sha256.txt`: implementation/dependency hashes.
- `step6_time0/`: config/environment, `runs.csv`, `summary.csv`, per-run JSONs, stage/native logs and solution checkpoints.
- `step9_time01/`: config, `runs.csv`, per-run JSONs, `*_solution.json` checkpoints, `*_cycles.csv`, `*_cycles_pricing.csv`, and `console.log`. This runner currently produces per-run rows rather than a separate average summary; with one run, the result is a single observation.

The console log contains startup, progress and errors. Step 9 demand CSVs contain pricing statuses, lower bounds and reduced costs; they are not native solver iteration logs. Completed error/guard rows are also retained on resume; inspect `validated`, `termination` and `error`. Do not treat such a row as a successfully solved instance. Rerunning a failed instance under changed settings requires a new output directory/configuration.

## Allocation and timing limits

Reading the original JSON dimensions gives the pricing variable upper bound `(2K+1)n(n-1)+2K`; SetA-20 has n=400 and K=6, giving 2,074,812. The default 200,000 pricing-variable guard would skip larger instances. This plan raises both the pricing and master variable allowance to 2,200,000 so that this known initial sizing barrier does not automatically disable large-instance pricing. The 100,000 pair-column limit remains a computation guard and can stop expansion with Not Optimal status.

**The 2.2-million-variable allowance is not a RAM cap, and large paired pricing memory has not been measured.** The tests so far cover tiny pricing MILPs and a one-second SetA-01 workflow check. The prepared one-pass commands have no external RAM watchdog. A large native pricing model can exceed the available memory; these settings are a pinned experiment configuration, not a capacity guarantee for this Mac. Allocation guards and SEARCH_WALL_LIMIT may end a run before its optimize allowance is consumed; preserve those stop reasons in the report.

At full allowances, aggregate optimize time is 20*1800 + 20*3600 = 108,000 seconds = 30 hours (10 hours Step 6 plus 20 hours Step 9), plus data loading, construction, pricing setup, validation, compilation and logging. This is neither a hard 30-hour completion promise nor an optimality guarantee. No full batch, cloud VM or background job was started while preparing this plan.
