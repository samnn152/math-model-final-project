# Challenge Orange attempt

Julia / Pluto coursework implementation of the Orange ROADEF 2026 challenge. The current implementation covers Data and the time-0 lexicographic model. **HiGHS is the default**, with SCIP retained for comparison. Automatic route columns reduce allocation for larger instances; validated MLU quality is reported against a global bound, with a requested gap ≤ 10%. Full lexicographic optimality is reported separately.

See [REFERENCE_AUDIT.md](REFERENCE_AUDIT.md) for the official-example comparison, independently exact optimum and known SCIP warm-start failure.

See [HIGHS_OPTIMIZATION.md](HIGHS_OPTIMIZATION.md) for the formulation, bound derivation, limitations and measured pilots, and [CHECKLIST.md](CHECKLIST.md) for pending coursework.

## Original material

- [Original challenge subject](Challenge_Orange_ROADEF_2026_Subject.pdf)
- [Original coursework instructions](readme), preserved verbatim
- [Routing calculation handout](calculating_r.pdf)
- Lecturer reference notebooks `json_to_graph_pluto_v2.jl` and `json_to_multigraph_pluto.jl`; the v2 copy includes earlier local coursework edits.
- `setA/`: supplied network, traffic-matrix and scenario JSON files.

Original material remains attributed to its authors. No additional license is asserted over it.

## Install and open Pluto

From this repository root, with Julia (tested with 1.13.1):

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=@orange-pluto -e 'using Pkg; Pkg.add("Pluto"); using Pluto; Pluto.run()'
```

Open `Project_Orange.jl`. It contains the lecturer graph-reader section, Data, original mathematical constraints, compact and route implementations, explanations and executable examples. The long batch is disabled by default. Its embedded environment is included.

## Run one job

Recommended on this Mac, with an isolated worker and deadline/memory supervision:

```sh
python3 scripts/run_guarded_highs.py --instance 20 --time-limit 1800 --target-gap 0.10 --output results/highs_ecmp_20_guarded
```

Use a new output directory. Read `guarded_result.json` and `experiment/` within it. See [EXPERIMENTS.md](EXPERIMENTS.md) for normal CLI runs, logs, resume and full coursework settings. No full batch has been run.

The routing default is next-hop **ECMP**, matching the original challenge; `--splitting uniform_paths` retains the calculation handout's alternative. Keep these conventions in separate directories. The time budget covers optimize calls only; setup and algorithm wall time are additional. Meeting the MLU threshold does not certify the full lexicographic vector.

## Verify

```sh
julia --project=. test/runtests.jl
```

Tests cover all 20 instances' Data, unequal shortest-path branches, tiny exact lexicographic optima, route/compact agreement, pricing against exhaustive enumeration, restricted-pool bound honesty and result/resume handling.

[DATA.md](DATA.md) explains parameters. [CODE_PERFORMANCE.md](CODE_PERFORMANCE.md), [SOLVER_COMPARISON.md](SOLVER_COMPARISON.md) and [MEMORY_PILOT.md](MEMORY_PILOT.md) retain historical compact-model measurements; their routing convention and configuration differ from current defaults. Results and native logs are local and ignored by Git.

The notebook now includes time-1 Data and the joint time-0/time-1 model with the original reconfiguration Budget. See [the implementation and local-test guide](docs/TIME01.md). The one-pass cloud batch runs on a dedicated GCP VM with two concurrent HiGHS jobs. See [CLOUD_RUN.md](docs/CLOUD_RUN.md) for deployment, resource guards, logs and checkpoints; the earlier [cloud assessment](docs/cloud-performance-cost-assessment.md) retains planning assumptions.

The current two-period default uses a paired-route master with demand-specific pricing MILPs. The original Budget and joint lexicographic objective are retained. Run the short fixture audit with `julia --project=. scripts/audit_time01_pairs.jl`; see [TIME01.md](docs/TIME01.md) for pricing bounds, logs and limitations. The separate-period formulation remains available for reference checks.

## Experiment archives and final campaign

The [first cloud pass](reports/2026-10-22-cloud-pass-01/README.md) is preliminary: one repetition per instance, not the required ten. It includes all 40 raw results and logs, the exact source archive, accepted MLU-quality rows and an analysis of the poor original Step 9 pricing performance.

The [repaired Step 9 local test](reports/2026-10-22-repair-validation/README.md) passes the requested 10% MLU-gap gate on SetA-19, with 3.8462% gap and original Budget compliance; full lexicographic optimality remains unproven. The [ten-run campaign](docs/TEN_RUN_CAMPAIGN.md) creates 400 uniquely indexed jobs across three disjoint VM shards, with seeds 1001–1010 and cloud-only progress email. Free Trial credit is used without upgrading to Paid. Final mean ± sample SD requires collecting all three shards.
