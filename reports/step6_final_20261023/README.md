# Step 6 — SetA results package

This package contains **200 completed runs: 20 original SetA instances × 10 seeds (1001–1010)**, at time 0, using HiGHS 1.15.1 and the original lexicographic objective. No experiments were rerun to produce these tables.

## Read the results

- [Statistical tables](STEP6_TABLE.md): dimensions, MLU mean ± sample SD, sample variance, best MLU, mean lower bound, mean gap, optimize! time, wall time, nodes and certified stages.
- [Full statistics JSON](statistics/instance_statistics.json) and [CSV](statistics/instance_statistics.csv): full precision, including median, minimum, maximum, sample and population variance for every metric.
- [Analysis and charts](STEP6_ANALYSIS.md) and [Vietnamese insights](INSIGHTS_VI.md).
- [Raw JSON index](raw_json/index.json): one bundle per instance, each containing its ten original result records, supervisor records, analysis records and paths to full solutions.
- `raw/step6_setA-NN_run-RR/`: original per-run result, full route solution, stage trace CSV, environment and configuration. The solution JSON retains the sorted load vector; the scalar MLU table does not replace it.
- [Independent primal audit](audit.json), [per-run audit](audit.csv), and [clean 200-run records](runs_clean.json).

## Statistical definitions

For each instance separately, with n = 10:

$$\bar x=\frac{1}{n}\sum_{r=1}^n x_r,\qquad s^2=\frac{1}{n-1}\sum_{r=1}^n(x_r-\bar x)^2,\qquad s=\sqrt{s^2}.$$

The displayed **± means sample standard deviation**, not a confidence interval. Population variance, also supplied in JSON/CSV, uses denominator n. No rounding is applied before calculating statistics. Zero objective variance means identical recorded MLU across runs; it does not establish optimality or identical routing.

The scalar `objective` is MLU, the first component of the lexicographically sorted normalized arc-load vector. Smaller is better. `lower_bound` and `gap` refer to this first component; `stage_gap` refers to the active lexicographic stage. Mean gap is the arithmetic mean of per-run `max(0, 1 − LB/UB)`, rather than a ratio of averaged bounds. Stored gaps are fractions; the Markdown table displays percentages. We do not pool objectives from different network instances into a single objective mean.

`cpu_time_seconds` is the sum of elapsed optimize! call durations (LP/pricing and MIP), **not OS CPU accounting**. `wall_time_seconds` measures the runner, and `process_wall_seconds` includes process startup. All times are seconds; time variances are seconds squared. Nodes and certified-stage counts are averages across the ten runs. They do not imply all those stages were optimal in every run beyond the reported per-run certificates.

## Results and limits

All 200 saved solutions passed the independent primal audit. **180/200 runs meet MLU gap ≤ 10%**, covering 18 instances. SetA-03 and SetA-19 do not meet that threshold. **0/200 have full lexicographic optimality certification**, so all retain `Not Optimal` for that objective. Certification counts are the original runner's numerical certificates; this audit did not independently verify dual proofs.

Mean optimize! time is **1715.65 s**; mean runner wall time is **1982.50 s**; mean process wall time is **2079.90 s**. The configured limit was 1800 s, but 119 runs stopped at the search-wall guard and 81 at the solver time limit. These timing limitations are preserved and discussed in the analysis.

The old aggregate `step6_runs.csv` mixed stage events with run records (53,987 rows); it is deliberately excluded from this published folder. Statistics are rebuilt from the 200 exact canonical run JSON files, with unique `(instance, run)` keys. The redundant source tarball and sibling ZIP are also excluded from Git. `sha256_manifest.json` preserves the original acquisition inventory (including the excluded source CSV); `package_checksums.json` inventories the files actually published here.

## Rebuild

From the repository root:

```sh
python3 reports/step6_final_20261023/rebuild_statistics.py
```

This uses only the Python standard library, checks all 200 canonical objective/bound/gap/time/status records against the clean dataset, and regenerates the tables, statistics and per-instance JSON bundles. It does not invoke Julia or a solver. Existing charts and the primal audit are retained from the independent analysis; this command does not regenerate them.
