# Challenge Orange checklist

Due: Sunday, October 25, 2026. Steps 1-3 are complete as reported by the project owner.

- [x] [S01] Read and understand the challenge description.
- [x] [S02] Build the nominal graph G(0) from network JSON using Pluto.
- [x] [S03] Read calculating_r.pdf and understand the calculation of r(i,j,a,0).
- [x] [S04] Prepare and verify the Data section from each instance's three JSON files.
  - [x] Read node and directed arc sets, metrics, capacities, and preserve JSON IDs.
  - [x] Calculate r(i,j,a,0) for every ordered vertex pair and physical arc.
  - [x] Read initial demand volumes v(d,0) and source/destination pairs.
  - [x] Read MaxSeg; keep all links available at time 0.
  - [x] Verify shortest-path ties, flow conservation, unreachable pairs, and all 20 SetA instances.
- [x] [S05] Implement and verify the time-0 optimization model without budget constraint (4).
  - [x] Define binary segment choices, flow conservation, segment limit, and arc loads.
  - [x] Implement the original lexicographic sorted-load objective using sequential top-k minimization and numerical locks.
  - [x] Exclude unreachable segments and validate returned routes and loads independently.
- [ ] [S06] Run SetA time-0 experiments with a 1800-second optimization limit.
  - [ ] Record vertices, directed links, demands, objective, optimize! wall time, status, bound, gap, and branch-and-bound nodes.
  - [ ] Average over ten runs as required by the report instructions; retain individual results and seeds.
- [x] [S07] Build G(1), removing only the directed link IDs listed for time 1; recompute parameters.
- [x] [S08] Extend the model to periods 0 and 1 and add reconfiguration budget constraints.
- [ ] [S09] Run final SetA experiments with a 3600-second optimization limit and the same result fields.
  - [x] Project owner confirmed Step 9 uses time periods 0 and 1 jointly with Budget; the original README wording is retained as received.
- [ ] [REPORT] Deliver a report of at most ten pages.
  - [ ] Introduction: context, motivation, problem description.
  - [ ] Mathematical model: data, variables, objective, constraints with explanations.
  - [ ] Numerical experiments: instances, environment, ten-run averages, CPU time, gap, branch-and-bound nodes.
  - [ ] Use gap = 1 - lower_bound / incumbent for nonoptimal minimization results; handle missing incumbents and zero objectives explicitly.

## Current implementation and verification

The default is next-hop ECMP, matching the original challenge subject. The calculation handout's complete-shortest-path convention remains selectable as `:uniform_paths`; do not mix their results. An unequal-branch test verifies that the conventions differ.

HiGHS is the default backend. Pluto retains the original compact constraints and adds an equivalent time-0 route formulation, bounded warm-start heuristics and full-domain LP pricing for global bounds. Restricted-pool integer optimality alone never certifies the original problem. See [HIGHS_OPTIMIZATION.md](HIGHS_OPTIMIZATION.md).

Data flow checks cover all 20 instances. Tests also cover exact tiny lexicographic solutions, route/compact agreement, exhaustive pricing comparisons, honest restricted-pool bounds, CSV schema and resume behavior. Pluto executes the visible examples with no errored cells.

One-run ECMP pilots on SetA-04, 09 and 20 met the requested global MLU gap ≤ 10%, with validated solutions. Only SetA-20 certified a lexicographic prefix (2/2000 stages); none certified the full vector. These pilots do not complete S06. Full 1800-second, ten-repeat experiments and report averages remain pending. A separate bounded pilot uses the continued-search policy on instances 04 and 09 only; no full batch was launched.

The CLI and optional macOS process supervisor checkpoint validated solutions and distinguish external interruption from optimality. See [EXPERIMENTS.md](EXPERIMENTS.md) for commands, timing, columns and logging.

The joint two-period model now defaults to paired-demand master–pricing. Small pricing oracles, Budget checks, legacy formulation regression, CLI resume and official-checker exports passed. Root column generation does not replace full branch-and-price; full SetA numerical experiments remain pending.
