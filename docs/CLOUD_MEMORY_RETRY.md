# Deferred memory retries — 23 October 2026

Each of the four existing e2-highmem-8 VMs (8 vCPU, 64 GiB RAM) runs a small `orange-memory-retry.service`. It publishes queue snapshots every 30 seconds while the current solver service continues. It does not stop or resize current solver jobs.

After the VM's current queue ends and no normal Julia process remains, the helper can run at most two Step 9 retries with a 24 GiB RSS guard per job. The service has a 56 GiB memory limit. The Step 6 VM additionally requires all its 200 assigned Step 6 jobs to be marked completed before switching roles. Two 32 GiB jobs are not enabled because they would consume the VM's entire physical memory.

Only explicit memory failures (`RSS_GUARD`, `LOW_SYSTEM_MEMORY`, `OOM`, `OUT_OF_MEMORY`, or a solver memory-limit termination) are eligible. Completed jobs and currently active jobs are excluded. A candidate's original owner must have stopped its normal queue, because that queue may still have a scheduled retry. Original result files and failed attempt logs are retained. New attempts write to `/opt/orange/results/memory_retry_20261023` on the VM that claims them.

The private GCS bucket `orange-coordination-201187524024` stores snapshots and exclusive claim records under `memory-v1/`. All four snapshots must be less than 180 seconds old. Claim creation uses a generation-match precondition of zero; simultaneous attempts produce one winner. Claims are never automatically stolen or deleted after a crash. An abandoned claim therefore needs manual inspection; this deliberately favors avoiding duplicate solver execution. A failed 24 GiB retry is recorded and is not repeatedly relaunched. There is no automatic escalation to 32 GiB.

Queue access is granted to the existing monitoring service account only on this bucket, with an expiry on 26 October. The bucket has a 14-day lifecycle for coordination objects; solver results remain on VM disks. No extra VM or paid-account upgrade was created. The helper stops when all normal queues and the shared retry queue have drained, or after its bounded runtime.

Hourly reports include local normal and memory-retry output folders. If all cloud snapshots are fresh, `global_unique_completed` reports the union of completed job IDs across VMs; this avoids counting a successful job twice. An individual VM's local count must not be added blindly to other local counts after retries move between machines.

## Verification performed

- Excluded jobs with an active original owner, completed jobs, active jobs, and failures unrelated to memory.
- Tested two simultaneous real GCS create-if-absent operations: exactly one succeeded; generation metadata was verified.
- Verified all four helpers publish snapshots and stay in `waiting_for_normal_jobs` while normal workers are active.
- Solver formulation, lexicographic objective, seeds and per-job solve-time budgets are unchanged. This only changes scheduling and the RSS guard for a subsequent memory retry.

Deployed code: `/opt/orange/recovery/shared_memory.py` and `/opt/orange/recovery/monitor_current.py`. Configuration and queue-only credentials are in `/etc/orange-memory/`, owned by the `orange` service user. Credentials are not stored in this repository.

## 23 October: immediate delegation to the idle Step 6 VM

After all 200 Step 6 runs completed, `orange-step6-worker` was idle. At 08:17 UTC on 23 October, its existing memory helper began running two Step 9 retries with a 24-GiB RSS guard each and the existing 56-GiB service limit. The first jobs were `step9_setA-05_run-02` and `step9_setA-05_run-03`. Their Project_Orange.jl hash matches the original Step 9 owners (`191b75ecd9bfd7bc473dc76b150a77dbe76bae705e097162c420e9f8d248808e`).

The old rule that blocked retries until an owner's entire queue finished was relaxed only for explicitly delegated jobs. There are 22 such memory failures on `orange-tenrun-02` and 24 on `orange-tenrun-03`. The owner launch scripts and existing job-specific script copies have a scheduling guard before notebook loading: jobs listed in `/opt/orange/recovery/delegated-jobs.txt` exit with code 75 and `DELEGATED_MEMORY_RETRY`, without launching a solve. A copy of the delegation list under `/etc/orange-memory/` is published in owner snapshots as `delegated_memory_jobs`. Only after the guards were installed was the Step 6 helper allowed to claim these jobs while their owners continue normal work. Generation-checked GCS claims and global completed/active exclusions remain in force. Already-running normal jobs were not stopped.

The guard was checked as the actual `orange` service user on both owners. These transferred jobs must be assessed from the shared retry supervisor/results and global job-ID union, not from the original owner's eventual code-75 status. Historical failure logs remain on their original disks. Runtime deployment backups end in `.before-delegation`; helper deployment remains `/opt/orange/recovery/shared_memory.py`. No notebook equations, seeds or solve-time limits changed.

### Automatic delegation of subsequent memory failures

`orange-auto-delegate.service` now runs on all three original Step 9 owners, polling every 30 seconds independently of the Mac. Its implementation is `cloud/auto_delegate_memory.py`, deployed under `/opt/orange/recovery/`. It identifies explicit memory failures from the existing snapshot logic, excludes completed and currently running jobs, installs the scheduling guard in source and private runner copies, atomically updates the delegation lists, then publishes a fresh process snapshot. Normal-owner retries exit with code 75; launches whose output is in the `memory_retry_` pool bypass that guard, allowing an idle owner to run shared retries later. Both guard paths were checked as user `orange`, without invoking the notebook or solver.

At deployment, the lists held 1 job on SetA, 22 on tenrun-02 and 25 on tenrun-03 (48 total). These include newly observed `step9_setA-11_run-01` and `step9_setA-05_run-09`. The existing two Step 6 retry processes remained running. Generation-checked claim records prevent multiple helper VMs accepting the same job. A failed 24-GiB attempt remains recorded and is not automatically retried without limit.

## Automatic 48-GiB escalation (23 October)

The user authorized one exclusive 48-GiB worker per VM for jobs that exceed the 24-GiB guard. `cloud/memory48_retry.py` is deployed as `orange-memory48.service` on all four existing VMs, with a 56-GiB service cap and no additional VM. It polls every 30 seconds. Eligibility requires an existing shared claim with `state=failed`, `rss_gib=24`, and `reason=RSS_GUARD`; time-limit failures and failed 48-GiB attempts do not escalate or loop automatically. SetA-05 runs 02 and 03 were the first two eligible jobs.

The service atomically replaces that job's terminal 24-GiB claim using its GCS generation and preserves the old claim in `previous_attempt`. Completed and active job IDs from fresh global snapshots are excluded immediately before the claim. Only one thread can execute a 48-GiB job on a VM. A stale or unavailable global inventory prevents new starts.

Before high-memory execution, `/opt/orange/recovery/reserve48` prevents *new* 24-GiB solves from starting. A scheduling-only gate was installed at the start of `execute_job` in each VM's configured source dispatcher. It waits only for the original 24-GiB output root; the distinct 48-GiB root bypasses the gate. Existing 24-GiB processes keep running with their existing RSS supervision, and normal Step 9 queues keep their concurrency. The 48-GiB service requires the normal dispatcher to be inactive, no Julia solve process to remain, and a reservation settling interval before claiming work. Thus it does not overlap an existing normal or 24-GiB solve. Pending 24-GiB claims may wait at the launch gate; their work is not marked completed or discarded. When no 48-GiB work remains for this VM, its reservation is removed and 24-GiB dispatch resumes.

Results go to `/opt/orange/results/memory_retry_48_20261023`. Successful recovery supervisors are mirrored into the original shared 24-GiB monitor root so the existing completed-job union and hourly monitor can find them. The old supervisor is retained as `supervisor_before_48.json`; all original 24-GiB logs remain, and the mirrored record explicitly points to the actual 48-GiB result file. Failed 48-GiB attempts remain terminal shared claims for manual review. No solver/model/seed/time-budget changes are made.

Validation: offline scheduling checks confirmed completed/active exclusion, rejection of non-RSS and already-48-GiB failures, and no launch on a failed compare-and-swap. The deployed dispatcher gate was exercised without a solver: a reserved 24-GiB root waits; the 48-GiB root passes. All four services reported active with two globally eligible jobs and `draining_for_48` at deployment. Existing Julia PIDs continued running. A full 48-GiB job has not yet completed at the time of this deployment note.

## Revision-bounded retry after the paired loop fix

After local SetA-05 and Linux reference tests passed, revision `stall_memory_v1` was installed in all four source templates and unfinished inactive private workers. Active normal jobs were not restarted. The old 48-GiB SetA-05 run 03, known to be repeating the stage-2 master, was explicitly stopped and recorded `CODE_UPGRADE` / `INTERRUPTED_FOR_CODE_UPGRADE`; it was not marked completed. Its outputs are archived by the next attempt. Each VM stores a rollout manifest with the exact notebook hash and skipped completed/active jobs.

`memory48_retry.py` now additionally accepts a small explicit legacy job allowlist from `/opt/orange/recovery/legacy48_revision_retry.json`: an old 48-GiB RSS failure or upgrade interruption may retry once with the corrected implementation. A new claim records `implementation_revision=stall_memory_v1`, so another failure under the corrected revision cannot trigger that exception again. Completed and active exclusions and GCS generation-checked claims remain unchanged. Ordinary 24-to-48 escalation still requires an actual 24-GiB RSS failure; no time-limit failure is promoted to a memory retry.

## Adaptive parallel recovery (23 October, 12:03 UTC)

`cloud/parallel_recovery.py` now runs as `orange-parallel.service` on all four VMs. It supersedes the previous recovery schedulers after their active jobs finish; existing Julia processes are preserved. Idle legacy recovery dispatchers are retired before their held claims can be adopted. New outputs use `/opt/orange/results/memory_retry_parallel_20261023`, which is included in snapshots and hourly reports.

The target is four solver workers per VM, with one HiGHS thread each. New ordinary jobs receive up to 12 GiB RSS; total reserved solver RSS, including legacy jobs at their original caps, must remain at most 52 GiB per VM. Transitional starts can receive 4–12 GiB while legacy reservations remain. A memory failure queues a bounded retry at 24 GiB, then 48 GiB; a 48-GiB job runs alone. No additional VM or change to the mathematical model, seed or solve-time allowance is involved.

The live audit at 12:03 UTC found ten actual Julia workers: four on SetA and two on each other VM, compared with six before deployment. The pool can rise to sixteen workers as legacy reservations are released. Global snapshots contained 307 completed jobs and 93 unfinished jobs, ten unique active job IDs, no duplicate active IDs and no completed/active overlap. Shared GCS generation-checked claims and a fresh global inventory are required before new starts. Completed jobs remain excluded.

## Live-RSS supplementary admission (23 October, 12:57 UTC)

`orange-adaptive.service` and `orange-adaptive-pressure.service` fill free slots without restarting the original scheduler, its supervisors, or any existing Julia process. Implementation: `cloud/adaptive_recovery.py` and `cloud/adaptive_slots.py`. A separate result root, `/opt/orange/results/memory_retry_adaptive_20261023`, is included in hourly reports; completed supervisors are mirrored into the shared retry inventory. The same generation-checked GCS claims prevent duplicate acceptance.

For admission only, a legacy worker reserves max(4 GiB, ceil(1.5 times observed RSS in GiB + 2 GiB)); its original hard limit is retained. Existing processes were protected from kernel OOM selection. Every subsequent dispatcher launch uses a common file lock around process creation, requires fewer than four actual Julia workers and at least 16 GiB MemAvailable, and waits for the child to become visible before releasing that lock. This also serializes admissions from the two dispatcher generations.

Supplementary workers ordinarily receive 12-GiB RSS guards, with a service memory.high of 30 GiB and memory.max of 37 GiB (increased for an admitted exclusive high-memory retry). A 0.5-second watchdog pauses only supplementary process groups below 12 GiB available and resumes above 18 GiB. Pausing does not free resident memory: below 8 GiB available it terminates only a supplementary attempt, which is queued for a higher-memory retry. Thus current jobs remain untouched by rollout and by the watchdog; newly added attempts can be retried under pressure. This is a headroom policy, not an absolute guarantee against arbitrarily fast host-wide allocation spikes. Pauses do not extend existing external wall deadlines.

The live deployment audit found four actual Julia workers on each VM (16 total), all ten pre-rollout PIDs still alive, 39.6–58.1 GiB available per VM, and no pressure pause. Original model equations, Budget, lexicographic objective, seeds and optimize-call budgets are unchanged. Offline checks cover four-slot capacity, exclusive 48-GiB admission, completed-job exclusion and failed-CAS rejection.

## Final incomplete-job recovery (24 October)

The Step6 VM stopped at its configured 36-hour maximum runtime. It was restarted with its persistent disk intact; its external address changed to 104.198.40.229. The old running claim for SetA-12 run 07 was reconciled with a generation-checked update only after verifying no Julia process and no final result on the recovered disk. No completed job claim was reset.

The external supervisor previously counted time spent waiting for the cross-dispatcher launch gate against its wall deadline. The execution clock now starts after process creation/admission. Step9's external watchdog is increased to max(21600, 4*limit+1800) seconds (six hours for the existing 3600-second optimize budget). This is an execution safety ceiling, not additional solver optimize time. The notebook's mathematical model, original Budget, lexicographic objective, seeds and existing internal search guard are unchanged. Some timeouts may also reflect expensive work outside optimize!, so excluding admission wait alone is not asserted to solve every case.

`cloud/final_recovery.py` runs an explicit, audited 11-job allowlist across the four existing VMs, at most three jobs per host, 12 GiB per job and 40 GiB per service. Old dispatchers were stopped only when no Julia process remained, and disabled to avoid restart competition. Fresh snapshots, completed/active exclusion and the same GCS compare-and-swap claim are required before any solve. Failed prior output directories are archived; completed job directories are excluded. Each allowlisted job gets one corrected attempt; failure is recorded rather than silently retried indefinitely. The final service continues publishing inventory even after its assigned solves finish, avoiding stale snapshots when one host finishes first. Hourly monitoring points to this service. The standard 36-hour VM safety stop is retained on the restarted VM.

Validation: Python syntax checks passed; the supervisor execution clock is structurally after Popen; the Step9 external ceiling evaluates to 21600 seconds; the Step6 wall rule remains unchanged. Cloud deployment compiles each modified dispatcher before writing. No extra VM or Paid upgrade was created.
