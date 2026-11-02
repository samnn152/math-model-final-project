# Local route and integer-bound verification

Verification is in progress. This directory does **not** claim a complete SetA-05
lexicographic optimum. No cloud campaign has been restarted or updated by these tests.

## Original instance and model

SetA-05 has 100 vertices, 396 directed physical arcs, 100 demands and MaxSeg = 6.
Step 6 uses time 0. Step 9 uses both periods and the original Budget = 1.
The objective remains the descending physical-load vector, optimized through
successive top-k sums. Original constraints remain documented in `Project_Orange.jl`.

The Budget counts changed ordered segment incidences. Equal flow balances in both
periods imply that at most one changed nonself segment is impossible. Consequently
Budget 0 or 1 requires equal segment incidences at the two periods. A common
simple SR route preserves a lexicographic optimum for these budgets. This reduction
is rejected for Budget >= 2 and is not applied to the general cloud formulation.

## Route generation and bounds

The experimental helper is `src/adaptive_integer_certificate.jl`.

- Direct and two-segment routes seed the pool; load-identical columns are merged
  using exact coefficient equality.
- Endpoint choices, bounded-hop dual pricing, repaired middle paths and flow
  decomposition supply additional complete routes. Every accepted route is checked
  against original loads, MaxSeg and temporal Budget.
- A restricted route MIP supplies upper bounds only. Its native dual bound cannot
  certify missing routes.
- A global integer relaxation retains each demand's first and last segment. Missing
  middle loads are restored progressively through continuous SR flow, then binary
  SR flow and MTZ constraints if necessary.
- When every nonzero ECMP coefficient is exactly one, a sparse binary physical
  middle path also supplies a valid global relaxation: an original middle physical
  walk can have its cycles deleted without increasing any load. Independent
  period flows relax the common-route requirement; they do not replace Budget in
  accepted solutions. No fractional ECMP coefficient is rounded to enable this mode.
- Physical paths become upper-bound candidates only after exact SR compression
  and original feasibility checks. Failed or unsupported physical arcs are excluded.
- A validated objective cutoff removes only solutions worse than an existing
  original incumbent. A rank is certified only when validated UB minus a global
  solver LB is at most 1e-7. Earlier locks allow 1e-7. Every rank is required for
  the numerical `Optimal` label.

## Observations already established

The old time-0 LP pricing certificate stalled at rank 3, despite MLU gap zero.
The integer endpoint bound certified rank 3 at 0.331670197882213. Generated routes
then certified rank 5 at 0.532786804815132.

The sparse integer physical relaxation certified time-0 ranks 6 through 9.
`stage10_probe.json` records the original-data hashes, preceding nine certificates
and a separate SCIP rank-10 probe: UB 0.904144862519234, LB 0.904144857757108,
46.264 optimize seconds. This is a single-rank diagnostic, not a complete run or a
controlled HiGHS-versus-SCIP benchmark.

Independent Python calculations use exact rational shortest-path distances and
ECMP fractions. Both saved original-instance solutions were feasible and their
load vectors agreed with Julia within 1.4e-17. That audit verifies feasibility and
load reconstruction, not the solver's global dual certificate.

The tiny original-subject fixture completed all 44 ranks for Budget 0 and 1 with
HiGHS, and all 44 ranks for Budget 0 with SCIP, matching the independent oracle.
The focused certificate, resume and native-continuation regression passed 40 assertions. The separate
route-generation regression previously passed 37 assertions.

## SCIP warm-start storage

SCIP.jl submits MOI starts as partial solutions. Repeated incremental solves hit
the default original-solution candidate limit after ten submissions. This is a
runtime integration error, not a mathematical infeasibility. The certificate helper
now submits a complete original solution and clears the MOI start attributes, so
the wrapper does not submit another partial copy. The normal storage limits remain
unchanged. A 44-rank SCIP fixture exercises the fix beyond the former failure point.
See the [SCIP parameter documentation](https://www.scipopt.org/doc/html/PARAMETERS.php)
and [partial-solution storage check](https://www.scipopt.org/doc-10.0.3/html/primal_8c_source.php).

## Current local pilots

`results/local_setA05_certificate_current/` points to the current diagnostic folder
with separate `pilot_step6` and `pilot_step9` directories. Each has a six-GiB
emergency RSS guard and uses one solver thread. Startup is staggered because the
notebook's existing demonstration cells write shared demo logs.

The runner is `scripts/test_seta05_integer_certificate.jl`. It executes the small
reference tests before the original instance, and returns a failed test unless
the original instance reaches the full numerical `Optimal` certificate. Native
per-rank logs, CSV bounds, exact certified locks and validated JSON checkpoints
are retained. Pilot budget defaults are 1800 optimize seconds for Step 6 and 3600
for Step 9; construction and compilation add wall time. Development attempts
interrupted to replace code are not independent experimental repetitions.

The Pluto checkpoint output reads these files without starting a solver. A saved
checkpoint's RUNNING termination describes its last update and does not establish
that the process is still alive. No full cloud rollout is enabled by these files.

Unchanged SCIP models now continue their branch-and-bound proof after a short
first slice. An unchanged objective cutoff is not rewritten, and no new start is
submitted on continuation. Dense SR refinement is triggered by a genuinely better
relaxed incumbent, rather than a dual gap alone. The native continuation test
stops a solve at a node limit and resumes it to its independently known optimum.

Checkpoints fingerprint the full mathematical data and preserve exact certified
top-k locks. Resume rejects changed data or proof tolerances and skips proved
ranks. Fresh optimize time and cumulative diagnostic time are separate. A resumed
diagnostic is not an independent lecturer-budget repetition. The current same-session
migration audits preserve the genuine prefixes 10/396 and 8/792 from unchanged
SetA-05 data; they certify no additional ranks and retain original raw evidence.
