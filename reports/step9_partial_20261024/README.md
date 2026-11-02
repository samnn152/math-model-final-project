# Step 9 interim campaign summary

Snapshot: 2026-10-24T02:04:02.615893+00:00 (UTC). 189 completed valid runs; 11 recovery attempts are still running. Step 6 was previously completed with 200 runs. This is not the final 400-job report.

Each job ID is counted once. Where historical and resumed copies differ, the newest result-file modification timestamp is selected, matching the earlier interim collection; affected IDs are recorded in results.json. Means and sample variance use completed valid runs only, not timed-out attempts or unfinished recovery checkpoints. Some implementation revisions and execution conditions differ between runs; this is not a controlled runtime benchmark. Objective means below refer only to MLU, the first coordinate, not the complete lexicographic vector. Gap is the mean of per-run global MLU gaps. Optimality of the full vector is a separate certificate. Validation and Budget checks use runner output, not an independent reconstruction of every route.

| Instance | n | MLU mean ± sample SD | Mean gap % | Mean optimize s | Mean wall s | Certified prefix min–max |
|---|---:|---:|---:|---:|---:|---:|
| SetA-01 | 10 | 0.929383900 ± 0 | 4.57476e-06 | 3600.0 | 4020.1 | 1–1/160 |
| SetA-02 | 10 | 0.903074709 ± 0 | 30.8731 | 3600.0 | 4855.4 | 0–0/300 |
| SetA-03 | 10 | 0.943543415 ± 0 | 32.8424 | 3119.9 | 7414.5 | 0–0/500 |
| SetA-04 | 10 | 0.581237186 ± 0 | 2.72047e-05 | 3523.8 | 4862.1 | 2–2/500 |
| SetA-05 | 10 | 0.204985875 ± 0 | 0 | 550.2 | 7521.6 | 1–1/792 |
| SetA-06 | 9 | 0.126760600 ± 0 | 22.2222 | 396.2 | 7532.1 | 0–0/1000 |
| SetA-07 | 10 | 0.907989441 ± 0 | 6.3952e-06 | 480.4 | 7533.5 | 1–1/1000 |
| SetA-08 | 10 | 0.318903697 ± 0 | 2.22045e-14 | 112.4 | 7661.0 | 1–1/1308 |
| SetA-09 | 9 | 0.849650000 ± 0 | 4.92469e-06 | 894.7 | 7229.8 | 3–3/1500 |
| SetA-10 | 10 | 0.071739161 ± 3.16e-09 | 3.03047 | 3460.5 | 7339.7 | 0–0/1932 |
| SetA-11 | 8 | 0.785788957 ± 0 | 1.11022e-14 | 663.4 | 7785.2 | 1–1/2000 |
| SetA-12 | 9 | 0.879872592 ± 0 | 0 | 2769.4 | 6718.8 | 1–1/1796 |
| SetA-13 | 10 | 0.041025600 ± 0 | 0.00025375 | 3600.0 | 4019.5 | 1–1/2000 |
| SetA-14 | 4 | 0.572103669 ± 0 | 9.52316 | 899.3 | 7500.2 | 0–0/2216 |
| SetA-15 | 10 | 0.898695808 ± 0 | 1.11022e-14 | 3600.7 | 4741.9 | 13–13/2500 |
| SetA-16 | 10 | 0.045081995 ± 1.58e-08 | 1.81852 | 1911.5 | 7501.9 | 0–0/2904 |
| SetA-17 | 10 | 0.424192341 ± 0 | 0 | 3601.1 | 4400.9 | 13–16/2540 |
| SetA-18 | 10 | 0.999998765 ± 0 | 6.1e-06 | 3601.4 | 4277.1 | 9–12/3000 |
| SetA-19 | 10 | 0.049203757 ± 0.000511 | 4.79809 | 3600.0 | 4885.9 | 0–0/3996 |
| SetA-20 | 10 | 0.991312385 ± 0 | 8.75784e-06 | 2410.4 | 7503.9 | 3–3/4000 |

15 instances have ten completed valid runs; 13 of those satisfy MLU gap <=10% in every completed run. Overall 160/189 valid runs meet that MLU target. SetA-02, SetA-03 and SetA-06 exceed it. None of the completed runs certifies the full lexicographic vector. A zero MLU SD does not imply identical routes or vectors, or optimality. Optimize time can be much smaller than wall time because dynamic pricing and model construction are outside optimize!. Earlier execution wall guards also ended some valid runs before the full optimize budget was used.
