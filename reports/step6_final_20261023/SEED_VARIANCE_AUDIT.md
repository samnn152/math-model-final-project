# Seed provenance and solution diversity audit

All **200/200** run checks pass. Each instance uses seeds **1001–1010**. For every run, the expected seed agrees with the result and supervisor, and the seed base/run number agree with the saved configuration and launch command. Every supervisor records successful completion with return code zero.

The experiment code computes `seed = seed_base + run` and passes it to HiGHS through `random_seed`. This audit checks the saved provenance; it does not claim to read back the RNG state inside the historical solver processes.

## Why MLU variance can be zero

MLU is only the maximum normalized arc load, the first coordinate of the lexicographic objective. Different route assignments and different complete load vectors can share exactly the same maximum. Thus zero MLU variance means the recorded first coordinate is unchanged across seeds; it does not establish identical routing or full lexicographic optimality. Changing a seed also does not require the solver to return a different solution.

For example, SetA-01 and SetA-20 each have one MLU value but ten distinct route assignments and ten distinct sorted load vectors. SetA-02 has one route assignment and one vector across all ten runs, while optimize! times, node counts and stage trace files differ across the ten records. The records therefore support separate executions that recovered the same solution, rather than ten copies of one result record.

Differences around 1e-17 in MLU (variance around 1e-34) reflect floating-point scale and should not be interpreted as practically meaningful solution variability. Exact numerical counts below retain such differences; no tolerance is applied.

## Ten-run diversity by instance

| Instance | Seed checks | Distinct MLU | Distinct route assignments | Distinct sorted load vectors | Distinct optimize! times | Distinct node counts | Distinct stage traces |
|---|---:|---:|---:|---:|---:|---:|---:|
| setA-01 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |
| setA-02 | 10/10 | 1 | 1 | 1 | 10 | 10 | 10 |
| setA-03 | 10/10 | 1 | 4 | 4 | 10 | 10 | 10 |
| setA-04 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |
| setA-05 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |
| setA-06 | 10/10 | 3 | 10 | 10 | 10 | 10 | 10 |
| setA-07 | 10/10 | 1 | 8 | 8 | 10 | 10 | 10 |
| setA-08 | 10/10 | 1 | 4 | 4 | 10 | 9 | 10 |
| setA-09 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |
| setA-10 | 10/10 | 4 | 10 | 10 | 10 | 10 | 10 |
| setA-11 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |
| setA-12 | 10/10 | 1 | 10 | 10 | 10 | 9 | 10 |
| setA-13 | 10/10 | 5 | 10 | 10 | 10 | 10 | 10 |
| setA-14 | 10/10 | 3 | 10 | 10 | 10 | 10 | 10 |
| setA-15 | 10/10 | 1 | 8 | 8 | 10 | 9 | 10 |
| setA-16 | 10/10 | 9 | 10 | 10 | 10 | 10 | 10 |
| setA-17 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |
| setA-18 | 10/10 | 1 | 8 | 8 | 10 | 10 | 10 |
| setA-19 | 10/10 | 9 | 10 | 10 | 10 | 10 | 10 |
| setA-20 | 10/10 | 1 | 10 | 10 | 10 | 10 | 10 |

## Counting rules and limits

- A route assignment is the complete set of demand/period waypoint sequences. Assignments are sorted by demand and period before comparison, so JSON record order cannot inflate the count. This counts whole-network routing solutions, not individual demand routes or ECMP physical paths.
- Load vectors are the complete saved nonincreasing normalized arc-load vectors, compared numerically without rounding. Equal sorted vectors need not imply equal loads on each named arc.
- Stage traces are compared by SHA-256 of their original bytes. Different measurements or timestamps can change a trace hash without establishing a different search trajectory.
- Node counts and elapsed times are supporting observations, not mathematical proof of RNG independence. Checkpoint reuse on resuming the same job is permitted by the runner; the audit finds no copied identical result record across the ten runs, and the run-specific seed provenance is consistent.
- This is an offline audit. No jobs were started, solver settings changed, or optimality statuses upgraded.

Reproduce from the repository root:

```sh
python3 reports/step6_final_20261023/audit_seed_diversity.py
```

Full per-run checks: [JSON](statistics/seed_diversity_audit.json). Compact summary: [CSV](statistics/seed_diversity_summary.csv).
