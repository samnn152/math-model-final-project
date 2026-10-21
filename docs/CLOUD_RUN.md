# Dedicated GCP worker deployment

The user authorized up to 1,000,000 VND of existing credit on 2026-10-21, without upgrading the Free Trial account. The selected worker is `orange-seta-onepass`, `us-central1-a`, `e2-highmem-8` (8 vCPUs, 64 GiB), Debian 12 with a 50-GiB balanced boot disk. It has no service account or attached Cloud API scopes. Source is transferred over SSH, not published to GitHub or a public bucket.

Compute runtime is capped at 36 hours per start with STOP as the termination action. The persistent disk and results remain after stop; storage charges continue until the disk is removed after exporting results. At the verified Iowa rate of $0.36159864/hour, 36 hours of compute is about $13.02; disk and IPv4 add approximately $0.43, before tax/exchange-rate differences. The corresponding planning estimate is about 350,000 VND, below the authorized reserve. This is an estimate, not a Google billing hard cap. No Paid upgrade, additional VM, GPU or commitment is part of this deployment.

## Source and setup

`cloud/build_bundle.py` creates an allowlisted archive of the exact current notebook, Project/Manifest, original SetA data, scripts and the tiny demonstration fixture. It excludes `.git`, old results and credentials. `cloud/bootstrap.sh` verifies the official Julia 1.13.1 Linux x86_64 checksum, installs dependencies and precompiles them entirely on the VM. Setup alone starts no experiments.

The Linux dispatcher defaults to planning only. `--run` rejects non-Linux systems so that the cloud launch path cannot accidentally start Julia solvers on the Mac. Every job uses a private source copy and its own output directory to avoid collisions from notebook demonstrations. One-pass tasks are all original SetA instances, one repetition each, seed 1001, HiGHS one thread, Step 6 time 0/1800 seconds, Step 9 joint periods 0–1/Budget/3600 seconds. The original objective and constraints are unchanged.

## Pilot and batch

`orange-pilot.service` runs only a 60-optimize-second Step 9 SetA-20 pilot. It samples process-tree RSS, observed kernel VmHWM and system available memory every two seconds. A 48-GiB RSS guard, 3-GiB available-memory floor, external process wall guard and a 56-GiB systemd memory ceiling bound the workload. The VM powers off automatically when the service completes or fails. Source and logs stay on its boot disk.

After a completed, validated pilot, `cloud/start_batch.sh` selects two workers if the observed peak is at most 20 GiB; otherwise it selects one. Two workers each have a 24-GiB RSS guard; one has 48 GiB. Short-run measurements cannot prove a long-run memory bound, so the guards remain active. On an error or resource stop, the dispatcher stops admitting jobs and cancels the other active job rather than consuming the rest of the credit blindly.

The batch service is detached from SSH, has a 35-hour service limit, and powers off the VM when finished or failed. The independent GCP 36-hour runtime limit is retained. The queue schedules joint Step 9 tasks before Step 6, larger instance IDs first; the experiments have no dependency on completing Step 6 first. With two workers, 30 aggregate optimize-hours suggest roughly 15 hours plus overhead, but this is not a completion/quality guarantee. With one worker, allowance is 30 hours plus overhead and the service limit may leave unfinished jobs.

## Results and resume

Remote outputs are under `/opt/orange/results/`:

- `pilot/`: single pilot supervisor record, memory samples, console and native runner outputs.
- `one_pass/step6_setA-XX/` and `one_pass/step9_setA-XX/`: isolated job directories, solver-result JSON/CSV, checkpoints, console and sampled memory logs.
- `one_pass/step6_runs.csv`, `step9_runs.csv`: collected per-run rows.
- `one_pass/queue-status.json`: supervisor outcomes.
- `one_pass/cloud-config.json`: settings and source fingerprints for resume.

A job counts as complete only if its process exits normally, its result is independently validated, and no ERROR/MODEL_SIZE_LIMIT is reported. Not Optimal/TIME_LIMIT with a validated incumbent is a legitimate completed experiment. Completed identical jobs are skipped on resume. Partial checkpoints do not restore a solver tree. Source/config changes require a new output directory.

Use the dedicated VM, not Cloud Shell, for long solver jobs. Cloud Shell/local CLI are only controllers. Once systemd is verified running, the Mac may be shut down without stopping the VM experiment.

## Controller paths

The current local SDK is `/tmp/orange-gcloud-sdk/google-cloud-sdk/bin/gcloud`, using `CLOUDSDK_PYTHON=/opt/homebrew/bin/python3.12`. It uses the user's existing GCP authentication; no access token is copied to the VM. The current allowlisted archive and SHA-256 are in `results/cloud_deploy/`. The temporary SDK path may disappear after reboot; reinstall the official SDK or use authenticated Cloud Shell for subsequent control.

`cloud/deploy_from_cloud_shell.sh` is an alternative controller with explicit preflight/create/setup/pilot/fetch actions. It does not automatically create or start resources. The live VM was provisioned through the local SDK after Cloud Shell keyboard automation proved unreliable.

## Immediate batch authorization

The user explicitly requested starting the entire batch immediately, without awaiting the capacity pilot. `start_batch.sh --skip-pilot` selects two workers with the same 24-GiB per-job and 56-GiB service guards. Stop the pilot before starting the batch, temporarily clearing its ExecStopPost shutdown hook so that stopping it does not power off the VM. This override does not claim a successful pilot or a measured long-run memory guarantee.

## Follow the running batch

The batch was started on 2026-10-21 at 14:15 Vietnam time with two workers. It schedules 40 jobs and 30 aggregate optimize-hours, with Step 6 limited to 1800 seconds and Step 9 to 3600 seconds per instance. This is one repetition, not the final ten-repetition coursework average.

In the VM SSH terminal:

```sh
sudo systemctl status orange-batch.service --no-pager
sudo journalctl -fu orange-batch.service
```

For a particular instance:

```sh
sudo tail -f /opt/orange/results/one_pass/step9_setA-20/console.log
```

Ctrl+C exits log viewing without stopping the batch. Disconnecting SSH or switching off the local Mac also leaves the systemd batch running. The journal may be quiet until a job finishes; detailed solver output is in each job's console and experiment directories. The service shuts the VM down on completion or failure, so a stopped VM alone is not proof of successful completion. Inspect the saved supervisor and queue records after restarting the VM to retrieve results.
