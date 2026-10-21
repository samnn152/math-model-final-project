# Implementation-only performance trial

Measured locally on 20 October 2026 against commit `b5d30db` with Julia 1.13.1,
SCIP 10.0.3, one solver thread and seed 1001. No route generation, candidate
pruning, solver tuning, or change to the mathematical formulation was applied.

The notebook now builds incoming/outgoing segment lists in one pass, uses a
compact integer array to map sparse routing rows to segment indices, and
suppresses automatic JuMP string names. Variable references remain available;
native solver logs may show generated names. All solver tolerances, starts,
variable order, constraints, and sequential top-k objectives are unchanged.

## Model construction

Median of five builds after warm-up, excluding explicit garbage collection.
Allocations count Julia heap allocation during construction, not native SCIP
memory or peak resident memory. Timings are local observations.

| Instance | Binaries | Before (s) | After (s) | Reduction | Julia allocation before / after (MB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| SetA-01 | 15,200 | 0.03369 | 0.02952 | 12.4% | 75.64 / 73.05 |
| SetA-02 | 39,150 | 0.08339 | 0.07565 | 9.3% | 174.88 / 168.38 |
| SetA-03 | 49,000 | 0.11002 | 0.10120 | 8.0% | 250.30 / 242.38 |

A differential check compared all native MOI constraint functions and sets,
objective, variable starts and physical-load coefficients on these instances:
969 checks passed. The existing 50 lexicographic/logging tests also passed.
The differential check and raw measurements are retained locally under
`results/code_performance/` (ignored by Git).

## Short solver trials

One run per version and instance, sharing five seconds across all optimize!
calls. These are exploratory trials, not the coursework's ten-run averages.
Reported values are maximum normalized loads, the first component of the
lexicographic vector. They are not certificates of the full vector.

| Instance | Before optimize! (s) | After optimize! (s) | Maximum load, both versions | Certified stages, both |
| --- | ---: | ---: | ---: | ---: |
| SetA-01 | 5.006 | 5.007 | 1.000000686 | 0 / 80 |
| SetA-02 | 5.011 | 5.018 | 1.000000000 | 0 / 150 |
| SetA-03 | 5.012 | 5.011 | 1.000001208 | 0 / 250 |

All six runs have status `Not Optimal`. Slight deadline overshoots are solver
termination overhead. The trials show no solver-speed improvement; they cannot
estimate time to full lexicographic optimality or support extrapolation to the
largest instances. The original model-size guard remains in force. SetA-20
still requires 957,600,000 binaries in this formulation.

Raw native logs, stage CSVs, solutions and measurements are under
`results/code_performance/before/` and `after/` locally. Older route-generation
pilot folders use a withdrawn algorithm and are unrelated to these trials.

## Repeat a short trial

```sh
julia --project=. scripts/benchmark_code.jl
```

This runs only SetA-01, 02 and 03, takes five construction measurements per
instance and allows five solver seconds each. It writes into
`results/code_performance/current/`. Notebook examples and solver warm-up run
before measurement. Process startup and compilation are excluded from warmed
construction medians; data timing can still contain compilation overhead.
Use a new output label when preserving previous logs:

```sh
julia --project=. scripts/benchmark_code.jl Project_Orange.jl trial2
```

An alternative notebook snapshot can be supplied as the first argument to
compare revisions. Keep the snapshot local; the script resolves its data paths
against this repository root.
