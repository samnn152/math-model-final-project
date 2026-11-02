# Step 9 interim results

Collected at 2026-10-23T12:21:49.559957+00:00. This is a partial campaign snapshot, not the final 200-run report. Only completed supervisors with available result JSON and validated=true contribute. Each job ID contributes once; where historical/resumed copies differ, the result with the latest file modification timestamp is selected. The 20 affected job IDs are preserved in results.json for provenance. These historical reruns must not be treated as additional independent runs.

Mean, sample SD and sample variance use available valid runs; SD and variance are undefined for n=1. The objective column is MLU (the first coordinate of the lexicographic vector), not the full vector. Gap is each run's logged global MLU gap averaged across runs. Optimize time sums optimize! calls and is distinct from wall time. Budget checks use the recorded budget_used and budget fields, alongside the runner's validated flag; this collection does not independently recompute routes. No new solve or cloud configuration change was performed. Results may span implementation revisions; this is campaign reporting, not a controlled speed comparison.

| Instance | n | MLU mean ± SD | Variance | Best | Mean LB | Mean gap % | Mean optimize s | Certified prefix |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| SetA-01 | 7 | 0.929383900 ± 0 | 0 | 0.929383900 | 0.929383857 | 4.57476e-06 | 3600.0 | 1–1/160 |
| SetA-04 | 7 | 0.581237186 ± 0 | 0 | 0.581237186 | 0.581237028 | 2.72047e-05 | 3600.0 | 2–2/500 |
| SetA-09 | 1 | 0.849650000 ± N/A | N/A | 0.849650000 | 0.849649958 | 4.92469e-06 | 3600.0 | 3–3/1500 |
| SetA-10 | 9 | 0.071739161 ± 3.33e-09 | 1.11e-17 | 0.071739160 | 0.069565125 | 3.03047 | 3446.9 | 0–0/1932 |
| SetA-11 | 2 | 0.785788957 ± 0 | 0 | 0.785788957 | 0.785788957 | 1.11022e-14 | 2552.5 | 1–1/2000 |
| SetA-12 | 7 | 0.879872592 ± 0 | 0 | 0.879872592 | 0.879872592 | 0 | 3549.2 | 1–1/1796 |
| SetA-13 | 10 | 0.041025600 ± 0 | 0 | 0.041025600 | 0.041025496 | 0.00025375 | 3600.0 | 1–1/2000 |
| SetA-14 | 4 | 0.572103669 ± 0 | 0 | 0.572103669 | 0.517621300 | 9.52316 | 899.3 | 0–0/2216 |
| SetA-15 | 10 | 0.898695808 ± 0 | 0 | 0.898695808 | 0.898695808 | 1.11022e-14 | 3600.7 | 13–13/2500 |
| SetA-16 | 10 | 0.045081995 ± 1.58e-08 | 2.5e-16 | 0.045081950 | 0.044262170 | 1.81852 | 1911.5 | 0–0/2904 |
| SetA-17 | 10 | 0.424192341 ± 0 | 0 | 0.424192341 | 0.424192341 | 0 | 3601.1 | 13–16/2540 |
| SetA-18 | 10 | 0.999998765 ± 0 | 0 | 0.999998765 | 0.999998704 | 6.1e-06 | 3601.4 | 9–12/3000 |
| SetA-19 | 10 | 0.049203757 ± 0.000511 | 2.61e-07 | 0.048711960 | 0.046838393 | 4.79809 | 3600.0 | 0–0/3996 |
| SetA-20 | 10 | 0.991312385 ± 0 | 0 | 0.991312385 | 0.991312299 | 8.75784e-06 | 2410.4 | 3–3/4000 |
