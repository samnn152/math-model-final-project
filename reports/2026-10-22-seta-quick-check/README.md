# Step 9 quick checks across the remaining SetA instances

Production notebook SHA256: `191b75ecd9bfd7bc473dc76b150a77dbe76bae705e097162c420e9f8d248808e`.

All 19 instances other than SetA-19 were tested with the unchanged production code, HiGHS, dynamic pair pricing, seed 1001, one thread and a 60-second cumulative optimize allowance. SetA-19 has a separate published 300-second local repair test. These checks are excluded from the ten-run campaign statistics. Each VM ran one extra low-priority process, CPU quota one core and memory limit 8 GiB. All quick-check services finished; all three production services remained active and retained the same notebook hash.

## Results and limits

19/19 returned validated feasible routes and consistent Budget, objective/bound/gap and status records. 16/19 certified an MLU gap at most 10%. This uses the solver's route validator (which reconstructs physical loads and segment changes) plus an independent record-consistency audit; it is not an independent implementation of the routing mathematics. No full lexicographic optimum is claimed.

| Instance | MLU | Global lower bound | Gap |
|---|---:|---:|---:|
| setA-02 | 0.903074709 | 0.624267428 | 30.873% |
| setA-03 | 0.943543415 | 0.633661120 | 32.842% |
| setA-06 | 0.126760600 | 0.098591550 | 22.222% |

These three cases remain quality/certification warnings, not demonstrated invalid models or solutions. A 60-second check does not establish their eventual 3600-second outcome. A large global gap does not show how far the incumbent actually is from the unknown optimum.

SetA-14 reached gap 9.523% but stopped at SEARCH_WALL_LIMIT: 49.130 optimize seconds and 420.585 solver wall seconds. Model construction/pricing overhead is material; do not report this as a full 60 optimize seconds. Other checks reached TIME_LIMIT, with small deadline overshoots recorded as actual time. The production time allowance and wall guard are larger; this short check does not guarantee they will consume their entire native solve allowance.

## Candidate change tested and rejected

On local SetA-02 and SetA-03, a candidate fallback called the existing exact excluded-pair pricer for rotating batches of at most eight demands on networks of at most 64 vertices whenever dynamic pricing stalled. At 60 optimize seconds, column counts grew from 81 to 141 and from 32 to 67 respectively, but MLU and global gaps did not improve. Solver wall time was 126.1 and 327.4 seconds. The change was reverted and never deployed. Excluded-domain bounds were not used as global bounds.

Production code was not changed: no correctness error was found, and the candidate repair did not demonstrate benefit. The three weak cases and SetA-14 overhead remain explicit limitations requiring observation in the actual campaign.

`results.csv` contains every check, including failures to reach the quality target. The three archives contain original JSON solutions/results, configurations, cycle/pricing logs, and journals. No repeated-run standard deviation is estimated from these single-seed checks.
