# Orange reference audit — 21 October 2026

The current time-0 HiGHS model passes an independently exact check on the **official subject's example** and produces a SetA-04 incumbent accepted by Orange's official checker. This does not prove the SetA-04 incumbent globally optimal. A separate, reproducible SCIP warm-start integration bug was found.

## Sources and scope

Official material index: https://roadef.org/challenge/2026/en/material.php

Official repository: https://gitlab.com/Orange-OpenSource/network-optimization-tools/challenge-roadef-2026

Pinned repository commit: `533033d67be88e2ccaeeddf55af345a1142012f7` (12 October 2026). Its subject PDF is byte-identical to the lecturer-distributed PDF in this project. The checker is version 1.2.4, built on macOS with Clang C++20 and networktools commit `f88536cb41d3b43e29045c40cf1c5700d084f3b5`. Build details and hashes are recorded in local `results/reference_audit_20261021/provenance.json`.

The repository includes public Sprint best-solution load vectors:
https://gitlab.com/Orange-OpenSource/network-optimization-tools/challenge-roadef-2026/-/blob/main/sprint_results/readme.md

These are best submitted feasible solutions, not published optimality certificates. The SetA-04 vector has 500 entries, combining 250 arcs and two periods, with leading entries 0.581237, 0.580857, 0.459119. Our coursework time-0 problem has 250 entries and no reconfiguration budget. Comparing their first components as if they solved the same optimization problem would be invalid. The three local SetA-04 input files were verified byte-identical to the official files. No certified time-0 SetA optimum was found in the inspected official repository.

## Published example versus independently established optimum

The subject's Sections 4–5 provide a seven-router, 22-arc, two-demand example, including its three JSON inputs. Table 2 gives exact ECMP coefficients; Figure 4 gives example MLU values. Those example solutions are not advertised as optimal.

The JSON examples are transcribed in `test/fixtures/orange_subject_toy/`. Derived files explicitly restrict the instance to time 0: one traffic entry per demand, no intervention/budget, MaxSeg = 4.

The independent Python oracle uses exact rational shortest-path metrics, exact next-hop ECMP flow fractions and exact rational load comparisons. Each demand has five possible internal routers and at most three intermediate waypoints. Removing waypoint cycles cannot increase any time-0 arc load, so enumerating all simple routes suffices:

    routes per demand = Σ_(h=0..3) P(5,h) = 1 + 5 + 20 + 60 = 86,
    complete routing schemes = 86² = 7,396.

Every complete scheme is evaluated and the entire decreasing 22-entry load vector is minimized lexicographically. The resulting exact optimum is

    (3/8, 3/8, 3/8, 1/3, 1/4, 1/4, 1/4, 1/6, 1/8, 1/8, 0 × 12).

One optimal routing uses waypoints [2,6] for demand 0 and [0] for demand 1 (original zero-based IDs). The optimum is independently computed from the official input; it must not be described as a published Orange optimality certificate. This argument does not establish anything about the later multi-period budget model.

## Measurements and checks

| Check | Outcome |
|---|---|
| Published Table 2 coefficients, including unequal shortest-path branches | Reproduced exactly |
| All 7 × 7 × 22 coefficients against independent rational ECMP | Maximum error 0 |
| Figure 4 baseline / waypoint example | Official checker reproduces 0.4375 / 0.3750 |
| Exact optimum, time-0 projection | MLU 0.375; all 22 sorted loads known exactly |
| Current compact HiGHS model | Optimal, 22/22, full vector error 0; optimize 0.242051 s |
| Current route HiGHS model, initial pool cap one | Optimal, 22/22, full vector error 0; optimize 0.332267 s |
| Official checker applied to both HiGHS solutions | Both valid; entire sorted vector matches within 1e-12 |
| Saved SetA-04 solution, explicit time-0 projection | Valid; checker MLU 0.459119346733; maximum arc-load discrepancy about 1e-12 |
| Unmodified compact SCIP implementation | Fails at stage 11 after certifying 10 stages; partial-solution storage error |
| Diagnostic SCIP run without repeated explicit starts after stage 1 | Optimal, 22/22, exact-oracle vector matches; optimize 0.279038 s |

Times cover optimize calls only. Each diagnostic solve had a 10-second upper limit; no long solve or additional SetA optimization was launched. Regression tests use a five-second ceiling per tiny HiGHS solve.

The official checker establishes feasibility and computes loads; it does not certify optimality. The toy's optimality comes from exhaustive enumeration, not from checker acceptance. Saturations omitted by the checker are padded with zero when comparing vectors.

## Diagnosis

### Mathematical model

No discrepancy was found in the current **time-0** ECMP coefficients, capacity normalization, segment limit, route choices or lexicographic objective on these checks. Compact and full-route representations attain the same independent optimum. This is evidence on a reference example, not a universal proof that every code path is correct.

The historical `uniform_paths` option differs from the subject's next-hop ECMP on unequal branches. Current defaults use ECMP and pass the subject's coefficients; earlier uniform-path measurements must remain separate.

### SCIP code integration: a real failure

The production compact solver sends a warm start on each lexicographic solve. The installed SCIP.jl wrapper submits starts using `SCIPcreatePartialSol` and `SCIPaddSolFree`. On this 22-stage case, stage 11 fails with:

    Cannot add partial solution to storage: limit reached.
    SCIPaddSolFree(o, sol__, stored_) yielded SCIP code SCIP_INVALIDCALL

The saved checkpoint shows 10 completed stages and stage 11 active. A controlled in-memory diagnostic changes only the repeated-start submission policy, leaving the model, coefficients, constraints and objectives unchanged. It completes all 22 stages and matches the exact vector. This localizes the failure to repeated warm-start handling in this solver integration. It is not evidence of an incorrect mathematical optimum.

The production notebook was deliberately not patched in this audit. `scripts/diagnose_scip_warmstart.jl` records the diagnostic change explicitly; applying a permanent fix and a dedicated regression remains separate work.

### SetA search and global certification

The route algorithm solves a restricted integer master and computes global lower bounds from an LP relaxation with pricing. It is not full branch-and-price. Finding the restricted integer optimum does not close an integrality gap for the original problem. Enumerating more routes without branching over the full route domain may therefore fail to prove optimality, even after 1800 seconds.

For saved SetA-04:

    global LB = 0.4590677738489471,
    feasible UB = 0.4591193467336683,
    MLU gap = 0.011233001852%.

The checker confirms the upper bound's feasibility. The remaining positive gap means the original MLU optimum could be below that incumbent. The available evidence does **not** distinguish “the incumbent already is optimal but unproved” from “a slightly better feasible solution exists.” It would be incorrect to claim this is only missing certification. The search method demonstrably lacks a complete certification mechanism for an incomplete pool, and its incumbent quality remains bounded by the reported interval.

## Reproduce the short checks

From the project root:

```sh
python3 scripts/audit_orange_reference.py --output results/reference_check/exact_oracle.json
julia --project=. scripts/audit_orange_reference.jl results/reference_check
julia --project=. scripts/diagnose_scip_warmstart.jl results/reference_check/scip_diagnostic.json
```

The comparison script records a SCIP error separately and continues to audit HiGHS; inspect its `errors` field as well as successful results. The SCIP diagnostic changes code in memory only. The Python script uses only the standard library.

The official checker can be built from the pinned official repositories with:

```sh
clang++ -O2 -std=c++20 -DNDEBUG -DLANG_EN main.cpp -I/path/to/networktools/networktools -o /path/to/checker
```

Run this from `checker/src`; see the official checker README for CLI flags. Checker binaries/source dependencies were kept outside the project in `/tmp` for this audit. Checker outputs, exact enumeration, Julia logs and diagnostics are retained locally in `results/reference_audit_20261021/`. The small fixtures and regression test `test/reference.jl` are part of the project. Production optimization code was not changed; no GitHub push was performed.

## Two-period extension, 2026-10-21

`test/fixtures/orange_subject_toy/expected_time01.json` contains independently computed rational reference vectors, not published SetA optima. `scripts/audit_time01_reference.py` enumerates the toy at Budget 20 (nonbinding) and Budget 0 (a common route in both periods). The Julia implementation certifies all 44 stages in both cases. The official checker accepts both, with exact Budget usage 7 and 0 respectively, and reproduces the entire sorted load vectors within 1e-12. A separate 10-second SetA-01 joint pilot is also accepted and matches all 160 loads within 1e-12. It has only 1/160 certified stages and is reported Not Optimal.

## Paired-demand pricing audit

The current paired implementation has an independent ordered-segment-sequence pricing oracle in `test/paired_pricing.jl`, covering Budget 0/3/20, signed dual costs, missing-column bounds and diversification exclusions. Run `scripts/audit_time01_pairs.jl` for short original-toy searches and optional official checker checks. Both two-second original-toy cases returned MLU 0.375 with 8/44 certified stages and were checker-valid. The older 44/44 result remains a separate-formulation exhaustive reference, not a result of the short paired search.
