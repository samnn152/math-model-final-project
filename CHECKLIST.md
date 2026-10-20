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
- [ ] [S07] Build G(1), removing only the directed link IDs listed for time 1; recompute parameters.
- [ ] [S08] Extend the model to periods 0 and 1 and add reconfiguration budget constraints.
- [ ] [S09] Run final SetA experiments with a 3600-second optimization limit and the same result fields.
  - [ ] Clarify README ambiguity: step 9 repeats “only time period 0” after the two-period extension.
- [ ] [REPORT] Deliver a report of at most ten pages.
  - [ ] Introduction: context, motivation, problem description.
  - [ ] Mathematical model: data, variables, objective, constraints with explanations.
  - [ ] Numerical experiments: instances, environment, ten-run averages, CPU time, gap, branch-and-bound nodes.
  - [ ] Use gap = 1 - lower_bound / incumbent for nonoptimal minimization results; handle missing incumbents and zero objectives explicitly.

## Routing convention to resolve before experiments

`calculating_r.pdf` defines r as the fraction of complete shortest paths using an arc.
The challenge subject (Section 2 and Table 2) uses equal splitting at each outgoing
shortest-path next hop (ECMP). These differ when branches contain unequal numbers
of shortest paths. The Data loader defaults to `:uniform_paths`, following step 3,
and also supports `:ecmp` for comparison. Record the selected convention in the report.

Step 4 verification: `julia test/runtests.jl` passed 837,918 checks across all
20 SetA instances and targeted routing cases. The updated Pluto notebook also
executed successfully as a Julia script on its selected setA-09 instance.

Experiment implementation is in `Project_Orange.jl`, with Terminal entry point
`scripts/run_experiments.jl` and instructions in `EXPERIMENTS.md`. The lexicographic
demo completes all four stages. A three-second setA-01 check records a validated
incumbent, zero MLU gap, and Not Optimal with 1/80 lexicographic stages complete.
The full 1800-second, ten-repeat experiments remain unrun. The explicit MILP's
size guard skips oversized instances honestly; those need a scalable method
before S06 can be completed.

SCIP is the default backend and HiGHS remains selectable. Both are checked on
the same known lexicographic example; native versions, solver-specific logs,
and backend-separated experiment metadata are implemented. Full benchmarks
remain unrun.
