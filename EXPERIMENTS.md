# Time-0 lexicographic experiments

SCIP is the default solver. HiGHS remains selectable for a controlled comparison.
Both are installed in the project environment and embedded Pluto environment.

The full implementation, mathematical model, and function explanations are in
`Project_Orange.jl`. The lecturer's v2 graph reader remains at the beginning.
No function is defined inside another named function. The independent lecturer
notebook is unchanged by these experiment additions.

## Objective and interpretation

For physical-arc loads sorted in decreasing order, solve

\[
\operatorname{lexmin}(\lambda_{(1)},\ldots,\lambda_{(m)}).
\]

Let \(F_k=\sum_{h=1}^k\lambda_{(h)}\). Solve for \(F_1\), lock its optimum,
then solve for \(F_2\), and continue through \(F_m\). Intermediate stages use

\[
F_k=\min_{\theta_k\ge0,\,e_{ak}\ge0}
\left(k\theta_k+\sum_a e_{ak}\right),\qquad
 e_{ak}\ge\lambda_a-\theta_k.
\]

Each completed optimum is locked within the recorded numerical tolerance
(default absolute 1e-7). This is sequential lexicographic optimization, with the
usual solver tolerances, rather than a small-weight approximation. The run is
`Optimal` only after all stages are certified. If any stage remains unfinished,
the run is `Not Optimal`, even if the maximum-load component is already optimal.

The model adds single-route degree constraints and continuous waypoint positions
to the subject's flow conservation, segment count, and physical load expressions.
These exclude disconnected cycles. Reachable segments only are candidates.
Incumbent routes and arc loads are independently reconstructed and checked.

The routing convention is recorded separately: `uniform_paths` follows the
provided calculation handout, while `ecmp` follows equal splitting at each next
hop. The convention remains an explicit choice; changing the objective to
lexicographic does not silently change the Data calculation.

## Set up and run

Run these commands from the project directory. Install the locked dependencies once:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

First perform one short trial:

```sh
julia --project=. scripts/run_experiments.jl --instances 1 --runs 1 --time-limit 30 --solver scip --output results/trial_lex_scip
```

Inspect `results/trial_lex_scip/runs.csv`, `summary.csv`, and the stage logs. A
30-second run may find an incumbent without certifying the entire vector; this
is expected and must appear as `Not Optimal` with explicit stage progress.

Assignment settings, including the README's ten repetitions:

```sh
julia --project=. scripts/run_experiments.jl --instances 1:20 --runs 10 --time-limit 1800 --solver scip --output results/time0_lex_scip 2>&1 | tee results_console_scip.log
```

The full configuration allows up to 100 hours of solver time in total, before
preprocessing. The implementation does not run this batch automatically. A full comparison
allows this budget independently for each backend.

To compare HiGHS with exactly the same instance IDs, repeat count, seed base,
time budget, routing convention and lock tolerance, change only the solver and
output directory. For a short pair of trials:

```sh
julia --project=. scripts/run_experiments.jl --solver scip --instances 1 --runs 1 --time-limit 30 --output results/compare_scip
julia --project=. scripts/run_experiments.jl --solver highs --instances 1 --runs 1 --time-limit 30 --output results/compare_highs
```

For a full comparison, use `--instances 1:20 --runs 10 --time-limit 1800` for each
solver. The same model-size guard applies to both. Each solver receives its own
small warm-up, outside the measured SetA solve times. Equal seed values control
repeatability within a backend; they do not force the same search across backends.

Without `--solver`, SCIP is selected. Without `--output`, the directory is
`results/time0_lex_scip` or `results/time0_lex_highs` according to the backend.
Saved config includes the solver and native version, so checkpoints cannot be
resumed with a different backend or version. Summary rows are grouped by both
solver and instance.

Other options:

```sh
julia --project=. scripts/run_experiments.jl --help
```

`--instances 1,2,3` selects a list. Seeds are `seed_base + run`, with default
`seed_base=1000`. One solver thread is the default for reproducibility. With SCIP, `--threads`
sets `parallel/maxnthreads` and `lp/threads` caps; ordinary SCIP.jl `optimize!`
uses `SCIPsolve`, not `SCIPsolveConcurrent`, so it does not automatically enable
parallel branch-and-bound. With HiGHS it sets the native `threads` option.
`--splitting ecmp` selects next-hop ECMP; use a new output directory.
`--lock-tolerance` controls the recorded numerical lexicographic lock tolerance.

Ctrl+C interrupts the batch. Run the identical command again to resume already
checkpointed repetitions without duplicating CSV rows. Settings must match the
saved `config.json`; choose a new directory for a different experiment.
Failed and size-limited repetitions also have checkpoints. A run interrupted
before its checkpoint is written is rerun from its first stage.

## Run in Pluto

Open `Project_Orange.jl` and scroll to **Mathematical model: time 0** and
**Numerical experiments and logs**. The small demonstration runs both backends automatically and displays the full
optimum `(1, 0.5, 0.5, 0)`, native versions and stage progress in a comparison table.
Its times are demonstration observations, not a performance benchmark.

For the batch, use `solver=:scip` or `solver=:highs` in `experiment_settings`,
choose a separate output directory for each, then change
`run_full_experiments = false` to `true`. Keep it false when only reading the
notebook. Run either the Terminal batch or the Pluto batch against a directory,
not both concurrently.

## Files and report columns

Each output directory contains:

| File | Content |
|---|---|
| `config.json` | Solver/native version, instances, repeats, time budget, seeds, convention, tolerances, limits |
| `environment.json` | Solver/native version, Julia/package versions, CPU, OS, architecture, threads |
| `runs.csv` | One row per repetition, bounds, gaps, status, progress, and paths |
| `summary.csv` | Per-instance averages, valid sample counts, and run counts |
| `setA-01_run-01.json` | Run checkpoint used for resume |
| `setA-01_run-01_stages.csv` | Every attempted lexicographic stage |
| `setA-01_run-01_stage-001.log` | Native SCIP or HiGHS solver log for stage 1 |
| `setA-01_run-01_solution.json` | Waypoints, arc loads, and sorted objective vector |

For the lecturer's scalar table, `objective` is the first vector component (MLU),
`lower_bound` is its stage-1 bound, and `gap` is

\[
1-\frac{\mathrm{lower\_bound}}{\mathrm{objective}}.
\]

Each run, stage, solution and summary records `solver` and `solver_version`.
The full objective is preserved as `sorted_loads_json`. Report
`lex_completed_stages/lex_total_stages` too. A scalar MLU gap is not a
certificate for the entire lexicographic objective and may be zero for a
`Not Optimal` run. The last attempted stage has separate `stage_objective`,
`stage_lower_bound`, and `stage_gap` fields. Its bounds are conditional on earlier
stage locks; do not interpret them as global MLU bounds or average stage gaps
from different stage indices together.

`cpu_time_seconds` is the sum of elapsed wall times measured immediately around
`optimize!`, excluding Data reading, construction, validation, and output writes.
All stages of one repetition share the 1800-second budget; it is not 1800 per
stage. Solver termination and wall-clock stop overhead can exceed the target
slightly. `nodes` sums the reported branch-and-bound nodes over attempted stages.

Missing incumbents produce empty objective/gap cells. Only a proof of
infeasibility at the first stage is reported as `Infeasible`. Missing observations
never become zeros in averages. The summary gives denominators and counts.

## Large-instance limitation

The explicit MILP uses |D| times |S| binary variables. SetA-20 has
957,600,000 binary variables, making this formulation impractical on a laptop.
The default guard checks for a maximum of 2,000,000 before allocation.

`MODEL_SIZE_LIMIT` means the solver was not run. These rows do not complete
the experiment requirement and are excluded from executed-run averages.
Raising the guard does not reduce the memory requirement.

An experimental route-generation reformulation was withdrawn after scope
clarification. It is not included in this repository, and its pilot results
must not be used to assess the current implementation.

## Validation

```sh
julia --project=. test/runtests.jl
```

Checks cover all 20 instances' Data, a small lexicographic optimum independently
enumerated by hand, incomplete-budget behavior, missing/zero gaps, route
validation, CSV escaping, checkpoint resume, and honest size-limit reporting.

## Backend settings and native logging

The mathematical model and sequential top-k objective are identical for SCIP
and HiGHS. Both use direct JuMP backends so model construction precedes the
measured `optimize!` calls. Shared numerical settings are zero relative gap,
absolute objective gap 1e-8, feasibility tolerance 1e-7, and lexicographic lock
tolerance 1e-7 by default.

| Setting | SCIP | HiGHS |
|---|---|---|
| Random seed | `randomization/randomseedshift` | `random_seed` |
| Relative gap | `limits/gap` | `mip_rel_gap` |
| Absolute gap | `limits/absgap` | `mip_abs_gap` |
| Feasibility | `numerics/feastol` | `mip_feasibility_tolerance` |
| Native log | Message-handler logfile API | `log_file` |

The log API for SCIP writes to a file while suppressing console output separately.
The code closes/flushes the native log after every stage, including error or
interruption paths. HiGHS logs are also closed after every stage.

For SCIP's incremental solves, the clock origin from `SCIPgetSolvingTime` is added
to the remaining allowance before setting the native limit. The sum of elapsed
wall times around `optimize!` remains authoritative for the shared per-run budget.

The small known optimum, incomplete-budget behavior, native log contents, solver
selection, backend-separated summaries and rejection of cross-solver resume are
tested for the selected backends. No claim of one solver being faster is made
from this small example.

Implementation references:
[SCIP.jl](https://jump.dev/JuMP.jl/stable/packages/SCIP/),
[SCIP parameters](https://www.scipopt.org/scip/doc/html/PARAMETERS.php),
[SCIP concurrent solving](https://www.scipopt.org/doc/html/CONCSCIP.php),
[JuMP API](https://jump.dev/JuMP.jl/stable/api/JuMP/) and
[HiGHS options](https://ergo-code.github.io/HiGHS/dev/options/definitions/).
