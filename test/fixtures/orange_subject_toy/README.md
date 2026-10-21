# Orange subject's seven-node example

Transcribed from Sections 4–5 of the original Orange ROADEF 2026 subject already distributed with this coursework. The local PDF is byte-identical to the official repository's subject at commit `533033d67be88e2ccaeeddf55af345a1142012f7`.

Source: https://gitlab.com/Orange-OpenSource/network-optimization-tools/challenge-roadef-2026/-/blob/533033d67be88e2ccaeeddf55af345a1142012f7/doc/Challenge_Orange_ROADEF_2026_Subject.pdf

Original material: Orange Research / challenge organizers; attribution and rights remain with its authors.

- `toy-net.json`, `toy-tm.json`, `toy-scenario.json`, `toy-srpaths.json`: examples printed in Section 5, including the sample output's waypoints. The sample output is not advertised as optimal.
- `baseline-srpaths.json`: no waypoints, the left-hand example in Figure 4.
- `figure4-srpaths.json`: waypoint 4 for demand 0 at time 0, the right-hand Figure 4 example. Their published maximum loads are 0.4375 and 0.3750.
- `time0-tm.json`, `time0-scenario.json`: explicit coursework projection to time 0 only, with no intervention/budget. They are derived files, not a new official dataset.
- `expected_time0.json`: **independently computed**, exact rational exhaustive optimum for the time-0 projection. It is not a published optimality certificate from Orange. `scripts/audit_orange_reference.py` enumerates 86 simple routes per demand, hence 7,396 routing schemes, and minimizes the entire 22-entry sorted load vector with exact fractions.

The proof uses the original time-0 fact that removing a repeated-waypoint cycle cannot increase any physical load. It does not extend this argument to the multi-period budget model.

- `expected_time01.json`: independently computed two-period vectors for the original toy at Budget 20 and a derived Budget-0 variant. At 20 the Budget is nonbinding; at 0 a common route suffices after removing common cycles. This justifies exact simple-route enumeration for these two oracle cases only. The Julia model itself retains vertex revisits. Reproduce with `scripts/audit_time01_reference.py` or the combined `scripts/audit_time01_reference.jl` audit; these are computed reference optima, not published Orange certificates.
