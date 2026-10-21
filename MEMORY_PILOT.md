# Single-job memory pilot

Measured on 21 October 2026, on the user's Apple M4 with 24 GiB unified memory.
Only one full-instance job was launched: SetA-04, SCIP 10.0.3, one solver thread,
seed 1001, 300 seconds shared optimize! budget. The compact model, uniform-path
routing convention, lexicographic objectives, presolve defaults and tolerances
were unchanged. No full batch or two-job trial was started.

## Observed peak and system pressure

| Metric | Observation |
| --- | ---: |
| Native peak memory footprint | 8,449,187,160 bytes = **7.87 GiB** |
| Native maximum resident set size | 5,116,968,960 bytes = **4.77 GiB** |
| Peak sampled process-tree RSS, every 3 s | **4.60 GiB** |
| Maximum increase in system swap used during trial | **209.56 MiB** |
| Kernel memory-pressure level | Normal (1) initially; warning (2) during trial; no critical (4) sample |
| Monitored process lifetime | **314.95 s** |
| optimize! time | **300.36 s** |

`/usr/bin/time -l` supplied the native high-water measurements. RSS counts
resident pages and can fall when macOS compresses or evicts pages. Footprint is
macOS memory accounting, not the same as resident uncompressed physical pages.
Do not use the lower RSS alone to budget simultaneous jobs. The 3-second sampler
can miss short peaks, hence its maximum is lower than the native maximum RSS.

System swap was already approximately 1.55 GiB at baseline and about 1.75 GiB
at the end; its whole amount was not created by this job. Machine-wide pressure
and swap include other applications and cannot be attributed exclusively to
Julia. Their deterioration while this job was running is relevant to how many
jobs this current desktop session can sustain.

Additional vmmap snapshots corroborated approximately 7.7–7.9 GiB peak footprint.
Their detailed malloc-zone analysis warned about tbbmalloc; rely on the native
`time` peak for the final number, not vmmap heap-category breakdowns.

## Optimization outcome

SetA-04 contains 50 vertices, 250 arcs, 200 demands and 490,000 binary segment
variables. The incumbent passed independent route/load validation.

| Metric | Result |
| --- | ---: |
| Best MLU | 0.6918238693 |
| Lower bound | 0.4590678030 |
| Assignment gap, 1 - LB/UB | 33.64% |
| Main search nodes | 1 |
| Certified lexicographic stages | 0 / 250 |
| Termination | TIME_LIMIT / Not Optimal |

Presolve took 33.70 seconds. The first root LP progress line appeared at roughly
282 solver seconds. Its incumbent and bound were unchanged at the deadline.
This is a load observation on this desktop session, not proof that memory
pressure alone explains the long root time.

## Can two jobs run together?

Two copies of this observed peak footprint would account for about **15.74 GiB**,
leaving about 8.26 GiB of the machine's nominal 24 GiB for macOS and other
applications, before any extra growth. However, even one job already coincided
with warning memory pressure and increased swap in the current desktop session.

**Recommendation: keep one SetA-04-sized job at a time in the current session.**
Two such jobs may fit after other applications are closed, but this pilot does
not demonstrate that they will run efficiently. It does not establish a safe
peak for a 30-minute solve: root cuts, branching and later lexicographic stages
can consume more memory than this five-minute window reached.

Before a two-job trial, reduce other application memory and confirm normal
pressure. Then use a bounded trial with an external monitor; do not start a full
parallel batch based only on doubling the current RSS. Smaller instances may
support greater concurrency, but were not measured in this pilot.

## Files and repeat command

Local logs, samples and native resource statistics are in
`results/memory_pilot_scip_setA04_300s/` (ignored by Git):

- `memory_summary.json`: native peak values and baseline/end system metrics.
- `memory_samples.csv`: RSS, CPU, pressure, compression and swap samples.
- `time_and_stderr.log`: original native resource high-water statistics.
- `console.log` and `experiment/`: solver logs, CSVs and validated solution.

Run one new pilot from the repository root with a new directory:

```sh
python3 scripts/measure_job_memory.py results/memory_pilot_repeat --instance 4 --solver scip --time-limit 300
```

The monitor stops the process tree if sampled RSS reaches 16 GiB, critical
pressure persists across two samples, or total process wall time exceeds the
solve allowance by 120 seconds. These are safeguards, not a reservation of RAM
or a strict per-solver memory cap. Building, startup, warm-up and teardown are
included in process lifetime; the CSV's optimize! time excludes them.
