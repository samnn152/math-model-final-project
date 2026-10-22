# Preliminary experimental analysis

## Scope and acceptance criterion

The first cloud pass ran all original SetA-01 to SetA-20 instances once for Step 6 and once for Step 9. Step 6 uses period 0 and a shared 1800-second optimize-call budget. Step 9 solves periods 0–1 jointly with the original Budget and a shared 3600-second optimize-call budget. The repeated “period 0 only” phrase in the original Step 9 coursework wording was interpreted, as agreed, according to the Step 7–8 extension. ECMP, capacities, demands, segment limits and the sorted-load lexicographic objective were retained.

A row is screened as acceptable **for MLU quality only** when its supervisor completed successfully, its incumbent passed the runner's independent route/load/Budget validation, its error field is empty and its valid global MLU gap is at most 10%. This is separate from whole-vector lexicographic optimality. Let U be incumbent MLU and L its valid global lower bound:

```math
L\le\operatorname{MLU}^{*}\le U,\qquad g=1-L/U.
```

A 100% gap with L=0 provides no useful proximity certificate. It does not prove that the incumbent is 100% worse than optimal. A certified prefix k/M means only the first k sequential top-k objectives have been certified at the stated numerical tolerances. It does not imply that the remaining M−k entries are optimal.

## Observations

| Measure | Step 6 | Step 9 |
|---|---:|---:|
| Runs returned | 20 | 20 |
| Validated incumbents | 20 | 20 |
| MLU gap ≤10% | 18 | 1 |
| Fully certified lexicographic optima | 0 | 0 |
| Median peak process RAM | 2.13 GiB | 6.45 GiB |
| Largest peak process RAM | 2.86 GiB | 9.49 GiB |
| Mean optimize-call seconds across instances | 1735.17 | 845.65 |
| Mean solver wall seconds across instances | 1966.46 | 3985.82 |

The averages in this table are **descriptive across 20 different instances**, not the required ten-run statistics for an instance. Optimize-call time is the elapsed execution of `optimize!`, matching the coursework definition of CPU time; it is not total operating-system CPU consumption. `solver_wall_seconds` begins inside the solver routine. `process_wall_seconds` additionally includes Julia startup, notebook inclusion and Data preparation.

Step 6 misses the target on SetA-03 (gap approximately 32.84%) and SetA-19 (16.67%). The accepted set is SetA-01, 02, 04–18 and 20. Step 9 accepts only SetA-01, whose MLU gap is approximately 0.0000464% with one certified stage out of 160. SetA-02 has a 30.87% gap. SetA-03 through SetA-20 all return 100% MLU gaps and no certified prefix. Their objectives remain close to the direct-route baseline near 1.

All 40 rows remain Not Optimal for the complete objective. A solver reporting an optimum within a restricted route pool is not sufficient for global lexicographic certification, so that local result was not relabeled Optimal in these tables.

## What is not acceptable yet

The first pass is insufficient as a final coursework experiment for two distinct reasons. First, it contains one repetition rather than the required ten, so sample SD and ten-run averages are unavailable. Second, most two-period runs fail the requested quality target. The full CSV includes them so the successful subset cannot hide the overall failure rate.

The saved-record audit found no inconsistent bound/gap, reported Budget violation, runner error or falsely declared full lexicographic optimum. This audit reads saved metadata and validation results; it is not an independent recomputation of all 40 routing tensors.

Step 9's SEARCH_WALL_LIMIT stop reason requires care: it does not mean that all 3600 optimize seconds were consumed. Across all 40 jobs, actual optimize-call time totals only 14.338 hours against 30 hours of configured allowance. In particular, SetA-19 used 186.64 optimize seconds but approximately 4072.88 whole-process seconds; SetA-20 used 184.44 optimize seconds and approximately 4135.38 whole-process seconds. Raising worker count alone does not correct this algorithm overhead.

## Root cause and repair direction

The old paired pricing routine rebuilt a large hop-indexed binary model separately for every demand. On SetA-19 it visited only 72 pricing subproblems for 6000 demands before reaching the wall guard. It retained 6000 candidate columns, the direct-pair baseline. Most of the elapsed time therefore bought model construction rather than a complete pricing sweep or useful integer improvement.

The repair being evaluated separately replaces bulk large-instance MILP pricing with shared hop-bounded dynamic programs, conservative full-domain pricing bounds, and valid route-pair column generation. It retains the original exact pricing MILP for reference. Endpoint assignment relaxations keep demands indivisible to strengthen the global MLU bound. Previously validated period-0 routes can initialize identical pairs in both periods with zero change cost, after both periods' coefficients are recomputed. These are candidate-generation and bounding changes; the original Budget and lexicographic objective remain.

Repair tests are not included in the first-pass tables and must not be mixed with them as extra repetitions. The repaired configuration must pass the single-instance quality gate before launching the new experiment campaign. Achieving a 10% MLU gap still does not authorize skipping the remaining lexicographic search while budget remains.

## Resource strategy

The VM has eight vCPUs and 64 GiB RAM. Cloud Monitoring provides 204 five-minute CPU observations for the batch window. Average utilization was 25.34%, median 25.46% and highest aligned mean 25.66%, equivalent to about 2.03 vCPUs used on average. Those values describe aligned observations, not instantaneous peaks. The original two single-threaded workers left CPU capacity unused.

Based on the first-pass RAM peaks, four concurrent Step 9 jobs with 12-GiB per-job RSS guards and six Step 6 jobs with 6-GiB guards are an initial conservative plan. A measured peak from the repaired implementation can support revising this plan; old pricing-MILP memory and new dynamic-program memory need not match. Phases should remain separated to make the aggregate memory allowances explicit. More workers may reduce total wall time but can also reduce per-job search progress under elapsed-time limits through CPU contention. Worker counts belong in the reported environment.

For ten repetitions of both stages the nominal allowance is 300 aggregate optimize-hours. With four Step 9 workers and six Step 6 workers, idealized optimize time is 200/4 + 100/6 = 66.67 hours, before construction and other overhead. With six workers for both stages it is 50 hours before overhead, subject to measured RAM feasibility. A runtime and credit plan must be chosen for the ten-run campaign rather than reusing the one-pass estimate.

## Reproducibility and next deliverable

The raw source archive has SHA-256 `1c85deface0a03b2330925bebde32d8f4cb9087cbdcbd713cc11a8288005b9e0`. Logs, checkpoints, solver versions, seeds, source fingerprints, parameter settings and memory samples are retained in the original results archive. The recorded solver is HiGHS 1.15.1; Julia setup used 1.13.1. Each first-pass job used seed 1001 and one solver/BLAS thread. The workload ran on a GCP e2-highmem-8 VM with a persistent 50-GiB disk.

The final deliverable still requires ten independent seeds per instance under one clearly recorded repaired configuration, all returned rows, per-instance mean ± sample SD, node counts, global MLU gaps, lexicographic progress and missing/failed counts. The first-pass files remain available as the baseline instead of being overwritten by that campaign.
