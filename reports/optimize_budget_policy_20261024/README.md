# Optimize-call budget audit and local verification

The production time-0 routes and time-0/1 paired searches previously imposed default wall guards in addition to the accumulated optimize! budget. The default is now no wall guard (`experiment_wall_deadline(..., nothing) == Inf`); a finite explicit diagnostic guard is still supported. Feasible routes, capacities, volumes, MaxSeg, Budget and lexicographic constraints are unchanged. Resource errors remain explicit stops, not optimality proofs. Zero MLU gap does not stop later stages.

Local verification on 24 October:

| Case | Method | Optimize allowance | Result | Certified prefix | Oracle comparison |
|---|---|---:|---|---:|---|
| Nontrivial time-0 demo, initial pool cap 1 | production route expansion | 5 s | Optimal; MLU gap 0 | 4/4 | vector [1,.5,.5,0], including post-MLU route expansion |
| Two-period toy, one allowed segment | production paired search | 10 s | Optimal within numerical tolerance | 44/44 | fixed-domain consistency, not a nontrivial route-choice benchmark |
| Original two-period toy, Budget 20 | production paired search | 30 s | Not Optimal; TIME_LIMIT | 8/44 | MLU .375; whole vector does NOT yet match the oracle |
| Original two-period toy, Budget 0 | production paired search | 30 s | Not Optimal; TIME_LIMIT | 8/44 | whole vector matches the oracle but certificate remains partial |
| Original two-period toy, Budget 20 | existing separate/full-enumeration reference | 15 s | Optimal; ~1.46 s optimize | 44/44 | whole vector matches oracle; Budget used 7/20 |
| Original two-period toy, Budget 0 | existing separate/full-enumeration reference | 15 s | Optimal; ~1.14 s optimize | 44/44 | whole vector matches oracle; Budget used 0/0 |

The paired tests consumed ~29.99/30.01 optimize seconds and ~42.50/37.89 wall seconds. An explicit 90-second diagnostic guard was set for those local tests and did not trigger. Removing wall guards fixes premature execution cutoff, but does not by itself fix an integrality/certification bottleneck in the paired decomposition. The reference result must NOT be reported as a full certificate for the paired production search. No production algorithm was switched to full enumeration.

`test/optimize_budget.jl` passed 17 assertions; the route-model regression file passed 37 assertions. The Pluto notebook has 239 unique, indexed cells after adding the timing explanation and helper. Other pending changes predate this policy change and are not part of this audit.

## Cloud rollout and experiment identity

The 11 running Step9 recovery processes retain their loaded legacy notebook: changing Julia source on disk does not safely replace compiled methods in an active process. Their PIDs/private notebooks are preserved, and only source templates are updated. Consequently those attempts can still report the old internal SEARCH_WALL_LIMIT and must retain their original policy label. No completed Step9 run is restarted.

A separately authorized rerun of all 200 Step6 jobs uses `/opt/orange/source-optimize-budget-v2`, outputs `/opt/orange/results/step6_optimize_budget_v2_20261024`, and IDs `step6v2_setA-NN_run-RR`. Four disjoint 50-job shards use seeds 1001–1010, 1800 optimize seconds per job, and new GCS claims under `memory-v1/optimize-budget-v2/claims/`. Original 200 Step6 results and their claims remain intact. At most four Julia processes may run per host across both campaigns through the same admission lock. The new cohort has 12-GiB per-job RSS guards and a 49-GiB service cap; it does not apply the old Step6 external elapsed-time cutoff. Existing VM maximum runtimes and resource guards remain safety limits and can still interrupt an experiment; such interruptions are not budget exhaustion or optimality.

Deployment verification at approximately 09:19 Vietnam time: 16 actual Julia processes (11 preserved Step9 and 5 new Step6), 200 unique new assignments, no duplicate actual job IDs. Initial caller/signature failures happened before Julia launched; only those explicit TypeError claims were retried after fixing the stop-event argument. All original result directories remain intact. Hourly reports append the new Step6 completed count separately from the original campaign.
