# Orange cloud pass 01 — preliminary, one repetition

**This is not the final ten-run coursework report.** Each instance has only one run (seed 1001). The required ten-repetition means and sample standard deviations cannot be obtained from this pass. `mean ± N/A` is used rather than inventing a zero standard deviation.

Of 40 completed runs, 19 meet the requested **validated incumbent plus global MLU gap ≤10%** screening criterion: 18 Step 6 instances and one Step 9 instance. This criterion does not certify the entire lexicographic objective. Every run remains **Not Optimal** for the full vector.

- [Analysis and limitations](ANALYSIS.md)
- [Accepted Step 6 table](accepted_step6.md)
- [Accepted Step 9 table](accepted_step9.md)
- [Accepted rows, full precision CSV](accepted_results.csv)
- [All 40 rows, including unsuccessful quality targets](all_results.csv)
- [Machine-readable summary](summary.json)
- [Recorded-result consistency audit](record_audit.csv)
- [Readable result and route JSON files for accepted runs](accepted/)
- [Original results, native logs, checkpoints, supervisor records and monitor history](original_results.tar.gz)
- [Exact runnable source archive used for the first pass](original_source.tar.gz)
- [Raw five-minute CPU observations](cpu_timeseries.json)
- [Archive SHA-256 checksums](SHA256SUMS)

The results archive omits disposable worker source clones. Its files are preserved as returned by the VM; absolute paths in metadata refer to the original cloud filesystem. No credential files are included.

## Meaning of ±

For ten observations of metric x, the final report must calculate

```math
\bar{x}=\frac1{10}\sum_{r=1}^{10}x_r,\qquad
s_x=\sqrt{\frac1{9}\sum_{r=1}^{10}(x_r-\bar{x})^2},\qquad
\bar{x}\pm s_x.
```

This pass has n=1, so the displayed mean is the single observation and sample SD is undefined. Solver gap is a bound-based quality measure, not a standard deviation, and is not substituted for it. No independent observations are created by copying a seed, re-reading a checkpoint or scaling a time limit.

For the final batch, all ten runs per instance must be retained, including missed quality targets; selecting only successful runs would bias the averages. Failed/missing metrics require their sample counts and failure counts to be disclosed.
