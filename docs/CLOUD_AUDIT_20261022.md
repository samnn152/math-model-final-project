# First cloud pass: results and resource audit

All 40 original SetA runs were collected from the stopped VM without overwriting them. The compressed original archive is stored locally under `results/cloud_collected_20261022/`; extracted solver outputs, supervisor records and monitor history are preserved there. `scripts/audit_cloud_results.py` writes the detailed acceptance table and JSON counts without starting solvers.

| Measurement | Step 6 | Step 9 |
|---|---:|---:|
| Completed/validated runs | 20/20 | 20/20 |
| Global MLU gap at most 10% | 18/20 | 1/20 |
| Peak process RSS across all runs | 2.86 GiB | 9.49 GiB |
| Median peak process RSS | 2.13 GiB | 6.45 GiB |

No inconsistent bound/gap, false full lexicographic Optimal status, runner error or reported Budget violation was found by the saved-record audit. This is an audit of recorded results, not a separate recomputation of every physical routing coefficient. None of the runs certified the entire lexicographic vector. Step 6 instances 03 and 19 missed the requested MLU threshold. Step 9 instances 03–20 all had zero global lower bound, a 100% reported gap and no certified prefix. Their valid incumbents do not establish proximity to the optimum.

## Bottleneck

The first Step 9 implementation rebuilt a hop-indexed pair-pricing MILP for each demand, with roughly two million variables for a large demand. SetA-19 visited only 72 demand subproblems, retained the direct-pair baseline and used 186.64 optimize-call seconds despite approximately 4073 seconds of total process wall time. The wall guard fired before meaningful column generation. This is an implementation/search weakness, not evidence that the original problem is infeasible.

## CPU and memory evidence

Cloud Monitoring returned 204 five-minute CPU-utilization observations over the first batch window (2026-10-21 07:15 UTC to 2026-10-22 00:15 UTC). The mean was 25.34%, median 25.46% and largest aligned mean 25.66%, equivalent to approximately 2.03 of the VM's eight vCPUs on average. This is a five-minute average, not an instantaneous CPU peak. Both workers and their solvers used one thread. The original two-worker limit left CPU capacity unused.

The proposed next configuration is four Step 9 workers (12 GiB RSS guard each) followed by six Step 6 workers (6 GiB each), with one solver/BLAS thread per process. The phases do not overlap: 48 GiB and 36 GiB are their aggregate job RSS guard allowances. A 56-GiB service memory ceiling, no swap allocation and the system-available-memory floor remain. Old-run peaks are evidence for planning, not guarantees for the changed column pool; a single repaired SetA-19 test must pass before the next batch starts.

The nominal optimize-call allowance is 20 hours/4 + 10 hours/6 = 6 hours 40 minutes, assuming all runs use their full limits. Actual wall time adds construction, pricing dynamic programs, validation and logging. CPU contention can change how much search each job completes within its elapsed optimize limit. Worker count is therefore recorded with the run configuration rather than treated as a free speedup.

## Repair

The paired master, Budget, reachability, MaxSeg, ECMP coefficients and sequential top-k objective are retained. The large-instance pricing sweep uses shared hop-bounded dynamic programs, adds only valid pairs and computes a conservative missing-column bound from independent routes and interpolated common-route costs. Original exact MILP pricing remains available as a reference. Small endpoint assignment relaxations retain indivisible demands to strengthen the MLU lower bound in both Step 6 and Step 9. Saved Step 6 routes can seed identical period pairs with zero Budget cost; their physical coefficients are recomputed.

The notebook states the formulas, lower-bound directions and restrictions of these methods. Dynamic-program wall time is not counted as optimize-call time; endpoint MIP calls are charged to the shared native-solve budget. A restricted pool's MIP bound is never relabeled as a global bound. The target is a validated result with global MLU gap at most 10%; this remains separate from certification of the whole lexicographic vector, and meeting it does not stop further search.
