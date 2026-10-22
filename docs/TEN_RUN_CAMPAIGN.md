# Ten-run SetA campaign

This replaces the preliminary one-pass plan for the final coursework experiment. There are 400 independent jobs: 20 instances × two stages × ten run indices. Seeds are 1001–1010 for every instance/stage. Step 6 has a shared optimize budget of 1800 seconds per repetition; Step 9 jointly solves time 0–1/Budget with 3600 seconds. MLU gap ≤10% is a quality report, not a stopping or lexicographic-lock rule.

## Preconditions and budget

The user increased the spending ceiling to 5,000,000 VND of existing Google Free Trial credit on 2026-10-22. No Paid upgrade or payment-card billing change is authorized. These E2 machines consume trial credit; they are not Always Free e2-micro instances. Actual provisioning is conditional on the trial account accepting it.

The measured quotas are 32 global vCPUs, 24 regional E2 vCPUs and eight regional external addresses. The selected plan is three e2-highmem-8 VMs (24 vCPUs, 192 GiB aggregate RAM), each with six single-threaded jobs. Each VM has a 50-GiB persistent disk, no attached service account/scopes, a 36-hour maximum run duration and automatic STOP. The workload service has a 35-hour limit and powers off after finishing or failing. Memory guards allow 8 GiB RSS per job, 48 GiB total allowance, a 56-GiB service ceiling, no swap and a 3-GiB system-available-memory floor.

A local SetA-19 test of the repaired Step 9 implementation must return a validated incumbent, Budget compliance and a valid global MLU gap ≤10% before new VMs or the campaign are started. Only that original SetA instance is used for repair experiments. The local test is not counted as one of the ten cloud repetitions.

At the previously verified Iowa highmem-8 rate of $0.36159864 per VM-hour, a hard 3×36 VM-hour allowance is about $39.05 compute, plus disks and IPv4. This is a resource/time envelope rather than a currency billing cutoff. It is comfortably below the 5M VND credit ceiling under the planning exchange rate, while actual billing remains subject to Google SKUs and currency conversion. See [Google pricing](https://cloud.google.com/products/compute/pricing/general-purpose). No commitment, Spot/preemptible VM or Paid upgrade is requested.

The nominal 300 aggregate optimize-hours divided by 18 workers is 16 hours 40 minutes. Actual wall time adds setup, pricing dynamic programs and validation; 20–28 hours is a planning range, not a deadline or optimality guarantee. CPU contention may change per-seed search progress, so the machine and worker counts are part of the experiment configuration.

## Sharding and run identity

The dispatcher enumerates stage, instance and run, then assigns positions modulo three to disjoint shards. Their sizes are 134, 133 and 133. The union contains all 400 jobs exactly once. A worker job invokes a single run using `--run-start`, and its JSON filename and `run` field retain that actual index rather than labeling all seeds run 1. Both stages on a VM use the same six-worker pool, with the Step 9 phase completed before Step 6. Jobs have isolated source copies, logs and checkpoints.

Each shard writes into `/opt/orange/results/tenrun_20261022/`. Per-job directories include stage, instance and run index. Runner JSON is authoritative. Aggregated rows and per-instance summary CSVs include all validated runs, not only quality successes. Mean and sample SD are computed only from available metrics with their sample counts; SD is missing for fewer than two observations. Per-shard statistics are partial until results from all VMs are collected together.

Completed matching jobs are skipped on resume, while settings/source mismatches require a new output directory. A checkpoint does not restore a solver's branch-and-bound tree. Full-vector Optimal still requires every lexicographic stage to have been globally certified; a restricted-master optimum alone does not suffice.

## Monitoring

Cloud monitoring runs on each VM, reads saved rows and only the latest memory samples, and sends a three-hour email for that VM's shard plus a terminal report. A dedicated writer credential has only a time-limited Cloud Logging writer role and is stored root-only. No local Mac or model inference is required. VM-specific progress/final policies prevent one VM's message from rate-limiting another's. Every email identifies the VM, assigned total and partial run statistics. Sum completed counts across all three shards for campaign progress; final ten-run averages require combining their results.

The monitoring timer stops after the local shard finishes. An abrupt power loss or forced stop can prevent the terminal hook from executing. Persistent disks retain results after STOP and should be exported before deletion.
