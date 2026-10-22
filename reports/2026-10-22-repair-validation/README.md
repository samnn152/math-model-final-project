# Step 9 repair — local acceptance test

Only the original SetA-19 instance was used for repair experiments. This accepted run was executed locally on macOS with Julia 1.13.1, HiGHS, one solver/BLAS thread, seed 1001 and a 300-second optimize-call budget. The Mac has 24 GiB RAM and 12 logical CPUs; the Julia process ran at lower scheduling priority. This is a repair test, not a repetition in the final ten-run campaign.

| Metric | First cloud pass, same instance | Repaired local test |
|---|---:|---:|
| Validated | yes | yes |
| MLU | approximately 1.000000 | 0.0487119600 |
| Global MLU lower bound | 0 | 0.0468383933 |
| Global MLU gap | 100% | **3.8462%** |
| Certified lexicographic prefix | 0/3996 | 0/3996 |
| Budget used / allowed | 0/13 | 3/13 |
| optimize-call seconds | 186.64 | 300.006 |
| Solver wall seconds | 3974.66 | 367.10 |
| Whole process wall seconds | 4072.88 | 422.42 |
| Peak resident memory | 8.15 GiB | 1.29 GiB |
| Status | Not Optimal | Not Optimal |
| Stop reason | SEARCH_WALL_LIMIT | TIME_LIMIT |

The different hardware and time limits prevent treating this table as a controlled speedup experiment. It demonstrates that the repaired implementation generates useful routes, returns a validated incumbent meeting the requested 10% MLU gap, and spends substantially more of its wall time in useful optimize calls. It does **not** establish that every other SetA instance will meet the target or that the whole lexicographic vector is solved.

The local run continued after first reaching the 10% MLU threshold. Endpoint bounding, master LP and master MIP optimize times sum to the reported shared total. Callback limits are cooperative, accounting for the approximately 0.006-second overshoot. No independent replicas are invented; sample standard deviation remains undefined for this single test.

The notebook retains the original constraints, Budget and sequential top-k objective. New shared dynamic-program pricing, common-route lower bounds and endpoint integer relaxations are explained mathematically there. The exact pair MILP pricer is retained for reference. Optional saved time-0 routes seed identical route pairs, which have zero reconfiguration cost and are revalidated using both periods' coefficients.

Raw result/checkpoint JSON, cycle logs, console output and `/usr/bin/time -l` measurements are included. `solver_function_sha256.json` identifies the core functions; subsequent CLI changes add run indexing and sharding without changing those core routines. The approved full campaign consists of ten distinct seeds per instance/stage and is reported separately.
