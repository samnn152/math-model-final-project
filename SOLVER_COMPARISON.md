# HiGHS versus SCIP: bounded time-0 trial

Observed on 21 October 2026. This is a six-run pilot, not the full coursework
experiment or a statistical ranking of solvers.

## Controlled settings

- Instances: SetA-01 (20 vertices, 80 arcs, 40 demands; 15,200 binaries),
  SetA-02 (30, 150, 45; 39,150 binaries),
  SetA-04 (50, 250, 200; 490,000 binaries).
- One run per solver and instance; seed 1001, one solver thread.
- Shared 30-second optimize! budget across lexicographic stages per run.
- Same compact segment formulation, positions, warm starts, sequential top-k
  objectives and tolerances. No route generation, custom cuts or branching rules.
- Routing convention remains `uniform_paths` for both, matching the current
  notebook. This trial is not a validation of that convention against the
  original challenge's next-hop ECMP definition.
- HiGHS 1.15.1, SCIP 10.0.3, Julia 1.13.1. Runs were sequential, alternating
  backend order for SetA-02. Notebook examples and solver warm-up were excluded.
- Native statistics were exported after optimize! without modifying the model;
  their export, model construction and validation are excluded from solve time.

The course techniques used are LP relaxation/bounds, primal incumbents,
Branch-and-Bound with native cut separation, and bound-based stopping.
Both solvers' standard MIP algorithms already use these mechanisms; this trial
compares their default search on the same model, not a new Bonobo implementation.

## End-of-run MLU and search progress

Gap is normalized consistently as `max(0, 1 - LB / UB)` for a positive
incumbent. Native solver percentage displays can use different denominators.
Nodes are the sum of native per-stage main-search node counts; restarts,
sub-MIP accounting and counting conventions differ between solvers.

| Instance | Solver | optimize! seconds | MLU UB | MLU LB | MLU gap | Nodes | Certified stages |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| setA-01 | highs | 30.019 | 0.929384 | 0.929384 | 0.00% | 433 | 1/80 |
| setA-02 | highs | 30.071 | 0.548578 | 0.548578 | 0.00% | 3 | 3/150 |
| setA-04 | highs | 73.809 | 0.691824 | 0.459068 | 33.64% | 0 | 0/250 |
| setA-01 | scip | 30.004 | 0.929384 | 0.929384 | 0.00% | 28 | 1/80 |
| setA-02 | scip | 30.009 | 0.548578 | 0.548578 | 0.00% | 2 | 1/150 |
| setA-04 | scip | 30.302 | 0.691824 | — | — | 0 | 0/250 |

All six runs returned `TIME_LIMIT` and overall `Not Optimal`. Every reported
incumbent passed the notebook's independent route/load validation. A zero MLU
gap means only stage 1 is certified, not the full lexicographic vector.

**Budget overrun:** HiGHS SetA-04 took 73.809 seconds inside optimize!, despite
a 30-second setting. The native log reports TIME_LIMIT and 73.47 seconds.
The measured overrun must be retained, not clipped to 30. This run is not an
equal-actual-time comparison with SCIP. Its final bound equals the value already
printed at 11.8 seconds, but the final state was obtained after the budget.
No additional full-instance runs were launched to compensate.

## Bounds for the active lexicographic stage

These are top-q sums, not MLU values. Rows with different q do not have directly
comparable UB/LB/gaps. A small gap at q=2 does not outrank certified progress to
q=4.

| Instance | Solver | Active q | UB of Fq | LB of Fq | Gap |
| --- | --- | ---: | ---: | ---: | ---: |
| setA-01 | highs | 2 | 1.520762 | 1.320237 | 13.19% |
| setA-02 | highs | 4 | 2.130836 | 2.088710 | 1.98% |
| setA-04 | highs | 1 | 0.691824 | 0.459068 | 33.64% |
| setA-01 | scip | 2 | 1.532468 | 1.320237 | 13.85% |
| setA-02 | scip | 2 | 1.089862 | 1.087348 | 0.23% |
| setA-04 | scip | 1 | 0.691824 | — | — |

## Root observations for stage 1

The first-LP log column is the elapsed solver timestamp of the first displayed
finite bound with positive LP iterations. It includes preceding work such as
presolve and is rounded to approximately 0.1 seconds. It is not an exact LP
solve duration or a promise that all root processing finished at that time.
SCIP also exports a native first-root-LP duration separately in stage_metrics.
No equivalent HiGHS duration was available through this instrumentation.

For the two small instances, both solvers proved optimality in the main root
node. Their complete stage-1 optimize! time is therefore the measured elapsed
time to proof at root, including presolve, cuts and primal heuristics/sub-MIPs.

| Instance | Solver | Presolve native s | First LP bound observed at s | Initial LP bound observed | Proof at root elapsed s |
| --- | --- | ---: | ---: | ---: | ---: |
| setA-01 | highs | 0.240 | 0.3 | 0.929384 | 1.489 |
| setA-02 | highs | 0.560 | 0.7 | 0.548578 | 5.017 |
| setA-04 | highs | 6.580 | 11.8 | 0.459068 | — |
| setA-01 | scip | 0.633 | 2.8 | 0.929384 | 9.672 |
| setA-02 | scip | 0.884 | 2.0 | 0.548578 | 8.942 |
| setA-04 | scip | 29.168 | — | — | — |

SCIP SetA-04 stopped during presolve, before a root LP bound was available.
HiGHS SetA-04 solved an initial root LP and continued separation, but processed
zero completed main-tree nodes and did not certify the root. Zero nodes is not
proof that the search tree was eliminated.

The original checkpoint recorded SCIP's finite numerical infinity sentinel
`-1e20` as if it were a real lower bound, producing a meaningless enormous gap.
Raw files are preserved. `comparison.csv` and `stage_metrics.csv` normalize
this sentinel and its gap to missing. The notebook bound reader was subsequently
corrected to call SCIPisInfinity; this is a reporting fix only. A future trial
uses the corrected reader. Both solvers in this trial used the identical saved
notebook snapshot and hash recorded in config.json.

## Interpretation

- HiGHS was faster to certify the MLU root on SetA-01 and SetA-02 in these runs.
- On SetA-01, both completed one stage. HiGHS found a better F2 incumbent
  (1.520762 versus 1.532468) with the same lower bound, despite processing more
  nodes.
- On SetA-02, HiGHS completed three stages, versus one for SCIP. Terminal gaps
  refer to different objectives and cannot be used alone to rank the runs.
- SetA-04 exposed a presolve bottleneck for SCIP and a deadline overrun/root
  bottleneck for HiGHS. These runs do not establish large-instance feasibility.
- No percentage of all possible branches pruned can be inferred from these logs.
  More processed nodes can coexist with better incumbents or greater progress.
- One seed/run is insufficient for a general claim that one solver is faster.
  These are implementation/machine/configuration-specific observations.

## Reproduce and inspect

From the repository root, use a new directory:

```sh
julia --project=. scripts/compare_solvers.jl results/solver_comparison_repeat
python3 scripts/summarize_solver_comparison.py results/solver_comparison_repeat
```

The script runs only the three listed instances, one run per solver. Native
time limits are cooperative and are not a hard external wall-clock deadline.

The original local output is `results/solver_comparison_20261021/`:

- `comparison.csv` / `comparison.json`: normalized run comparison.
- `stage_metrics.csv` / `stage_metrics.json`: root observations and per-stage bounds.
- `runs.csv`: original run records, including the documented SCIP sentinel.
- `scip/` and `highs/`: native stage logs, stage CSVs, statistics and solutions.
- `config.json` / `notebook_snapshot.jl`: reproducibility configuration and source.

Generated results remain ignored by Git. No full 20-instance batch was run.
