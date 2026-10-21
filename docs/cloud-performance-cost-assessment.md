# Cloud performance and cost assessment

Verified 21 October 2026. Repository: `challenge-orange-attempt`. Prices are public USD list prices, not a negotiated quote. No VM, service, bucket or billable benchmark was provisioned. Production code was not changed for this assessment.

## A. Executive summary

**For Step 6 alone**, four isolated Julia processes on one `e2-highmem-8` (8 vCPU, 64 GiB), on-demand in `us-central1`, are the provisional recommendation. The budget-defined projection is **27.75 hours**, about **296,238 VND** service consumption; reserve about **350,000–550,000 VND** pending measurements and billing/tax verification. This fits comfortably inside the currently displayed 7,897,351 VND trial credit. It does not imply optimal solutions or guarantee sufficient memory on every large instance.

The workload's “100 hours” is **20 instances × 10 repetitions × 1800 seconds = 200 solve attempts**, not a measured 5-hour runtime for a single solve. This report treats the requested 20 jobs as **20 instance bundles**, each containing ten runs. If only one repetition of each instance is intended, the nominal solve budget is 10 hours, not 100; four workers would need about 3 hours including modeled overhead/setup.

**Scope update for Steps 6 and 9:** running both full experiments at their stated limits means 100 + 200 = **300 optimize hours**. Four workers need at least 75 hours before overhead, approximately **82.75 hours** at the modeled 10% overhead. Even eight equally effective workers need at least 37.5 native hours. Meeting 28 hours with full budget consumption needs at least 12 concurrent solve processes (about 27.75 hours with overhead), with unverified performance/RAM and no retry margin. The current Free Trial ceiling does not provide 12 independent vCPUs. Oversubscribing 12 processes on eight vCPUs may consume wall-clock limits faster without equivalent search work; it is not a defensible substitute. Do not reduce repetitions, alter datasets, shorten limits or promise complete certification silently.

**User's current instruction:** implement/validate Steps 7–8 locally first. Preserve original SetA instances. Prepare VM configuration only; do not create or start it. The combined 28-hour target remains conditional on confirmed scope, account quota/upgrade or early finishes, and local/cloud measurements.

## B. Repository findings and measurements

### Execution architecture

- `scripts/run_experiments.jl` includes `Project_Orange.jl`; `run_seta_experiments` loops instances then repetitions **serially**. Defaults are HiGHS, ECMP, 10 repeats and 1800 seconds shared across all lexicographic optimize calls.
- `solve_time0` holds a process-wide `ReentrantLock`; HiGHS has a global scheduler. Threading multiple solves inside one Julia process would serialize them and risk global native state. Use external processes, not `Threads.@threads` around this wrapper.
- No active task-level `Distributed`, `pmap`, `@spawn` or `Threads.@threads` scheduler exists. `Distributed` in the embedded Manifest is a dependency listing, not an active parallel implementation.
- HiGHS is configured with one solver thread; LP pricing uses one thread. Julia thread count and both BLAS runtimes must be pinned explicitly in the cloud. A one-thread solver setting alone is not proof that all libraries use one thread.
- Work is primarily CPU/search-bound, with potentially memory-limited construction, route pools and solver trees. It is not dominated by network I/O after dependency installation. No GPU path exists.
- Julia 1.13.1, JuMP, Graphs, JSON3, SparseArrays, HiGHS.jl 1.26.0 / native 1.15.1 and SCIP.jl 0.12.8 / native 10.0.3 are recorded. Install matching **Linux** artifacts rather than copying macOS binaries. Linux/JLL compatibility must be smoke-tested.
- Known compact SCIP repeated-warm-start failure is documented in `REFERENCE_AUDIT.md`; cloud hardware will not fix that integration bug. Current planning uses HiGHS. Extra compute also cannot supply a missing global optimality proof automatically.

### Independence, shared state and recovery

Instance bundles are independent. Within a bundle, repetitions use `seed_base + run`; within a repetition, lexicographic stages are sequentially dependent. Budget constraints in the forthcoming two-period model also couple periods; they cannot be solved as independent period jobs.

**A concrete concurrency hazard:** notebook inclusion executes demonstration cells, which write `results/demo_scip/...` and `results/demo_highs/...` relative to the notebook directory. Merely specifying distinct batch `--output` paths does not isolate those writes. Each process needs its own repository/work directory or isolated container filesystem. CSV summaries, config files and fixed `.tmp` filenames must never have concurrent writers.

Final per-run JSON checkpoints are atomic and enable skipping completed runs with matching config. Saved partial solution JSON preserves a validated incumbent, but the code does **not** reconstruct the route pool, previous lex locks or solver tree from it. Interrupted in-flight runs restart. Error/size-limit result rows must not be mistaken for successful completed runs by an external retry policy. The current macOS Python supervisor uses `sysctl` and `vm_stat` and cannot run unchanged on Linux; a Linux watchdog/cgroup sampler is required before cloud execution.

### Verified versus unknown metrics

| Metric | Evidence / limitation |
|---|---|
| SetA-04 current 1800s solve | 1800.012875 s optimize; 1936.823670 s solve-routine wall; 1951.270954 s supervisor wall including startup |
| Startup and outside-routine delta | 14.447284 s in that warmed local launch; not a clean Julia compilation benchmark |
| Current SetA-04 memory | 2.171 GiB peak sampled RSS **after supervisor handoff only**; not a full-run peak |
| Earlier 04/09/20 short route process | 95.43 s real, 94.97 s user + 2.25 s system: 1.019 CPU equivalents averaged over the whole process; native footprint about 1.00 GiB, RSS about 1.08 GiB; different earlier search policy |
| CPU average/peak, current 1800s policy | Not recorded; one configured solver thread, occasional ancillary/GC threads possible |
| Historical compact SCIP CPU | 104 samples, mean 97.47%, peak 100%; **different solver/model configuration**, not a current HiGHS benchmark |
| Historical compact SCIP footprint | 7.87 GiB; not interchangeable with route-model RSS |
| Largest SetA-20 current long-run RAM | Unmeasured; 60s earlier-route observation is insufficient for 1800/3600s growth |
| Input size | SetA directory about 5.2 MiB allocated |
| SetA-04 output | About 0.824 MiB apparent data, 3.1 MiB filesystem allocation, 763 files in the completed experiment directory |
| Julia depot on this Mac | Packages about 135 MiB; artifacts about 1.2 GiB; Linux install sizes may differ |
| Disk throughput / peak IOPS | Not measured. Old native block-operation counters of zero do not prove zero I/O; buffered filesystem writes occur |
| Network | No per-iteration service dependency found; package downloads and artifact upload/download dominate network usage |

Use 50 GiB boot/work disk provisionally. Plan **12 GiB per unknown large worker plus 4 GiB for OS/controller**: four workers need 52 GiB, leaving 12 GiB headroom on a 64-GiB VM. This is an admission assumption, not a measured bound. If a local 3600s worker exceeds it, resize or lower concurrency rather than silently accepting failed runs.

## C. Performance model

### Budget-defined runs versus fixed work

Let N=20 bundles, r=10 runs/bundle, L=0.5 native wall-hours/run and overhead a=10%. One bundle is provisionally B=rL(1+a)=5.5 hours. One VM setup allowance is h0=0.25 hour, unverified. With equal bundles and p workers:

    T_budget(p) = ceil(N/p) B + h0.

The observed SetA-04 ratio 1951.27/1800.01 ≈ 1.084 supports using 1.10 as a starting allowance, not as a guarantee for all instances. Early optimal solves can shorten a bundle; memory failures do not count as valid completion.

For **time-limited** runs, faster CPUs generally do more search inside the same 1800-second allowance; they do not turn it into 900 seconds automatically. Conversely, a slower cloud CPU can return a weaker incumbent in the same time. This distinction is essential to both quality and billing.

For a hypothetical **fixed-work / convergence-defined** workload, let s be cloud speed relative to local and eta be parallel efficiency from contention. Then B_cloud=B/(s*eta), not B/s with presumed linear scaling. The required sensitivity analysis below is for this separate interpretation. It must not be used to multiply/divide the assignment's solver wall-time limits.

### Unequal jobs and scheduling

Individual cloud runtimes are unknown, so an “actual” per-instance schedule cannot be fabricated. Use a pull queue with larger estimated bundles first; each worker requests the next unfinished bundle. Given estimates t_i, assign each next item to the least-loaded worker (LPT), and report makespan max(worker_loads). Lower bound is max(sum(t_i)/p, max(t_i)); list scheduling is at most sum(t_i)/p + (1-1/p)max(t_i). Replace the equal-bundle estimates after profiling. A queue of individual repetitions balances better, but needs a wrapper preserving true run IDs/seeds; the existing `--runs 1` always reports run 1.

### Worker scenarios, Step 6 only

The following table uses **budget-defined** equal bundles, no retries, no sustained/committed discount, Iowa, 15-minute setup, and itemized storage/IP plus a shared $1 allowance. It does not claim measured parallel efficiency. The ten/twenty-worker designs reserve two vCPUs and 16 GiB per process using multiple VMs.

| Scenario | Architecture (us-central1) | vCPU | RAM GiB | Workers | Time h | Total VND | Credit used |
|---|---|---:|---:|---:|---:|---:|---:|
| Lowest-rate baseline | 1 × e2-standard-2 | 2 | 8 | 1 | 110.25 | 252,733 | 3.20% |
| Two workers | 1 × e2-standard-4 | 4 | 16 | 2 | 55.25 | 236,180 | 2.99% |
| Conditional minimum: three | 1 × e2-highmem-4 | 4 | 32 | 3 | 38.75 | 220,686 | 2.79% |
| Four, lean RAM | 1 × e2-standard-8 | 8 | 32 | 4 | 27.75 | 228,558 | 2.89% |
| Recommended: four | 1 × e2-highmem-8 | 8 | 64 | 4 | 27.75 | 296,238 | 3.75% |
| Five, conditional | 1 × e2-highmem-8 | 8 | 64 | 5 | 22.25 | 242,691 | 3.07% |
| Ten: Paid/quota required | 10 × e2-highmem-2 | 20 | 160 | 10 | 11.25 | 325,953 | 4.13% |
| Twenty: Paid/quota required | 20 × e2-highmem-2 | 40 | 320 | 20 | 5.75 | 332,618 | 4.21% |

**RAM/CPU gates:** baseline one/two-worker small VMs require measured worker RSS ≤ about 6 GiB. Three workers on highmem-4 require ≤8 GiB each and satisfactory SMT contention tests. Four lean workers require ≤6 GiB each. Five highmem workers require ≤10 GiB each and acceptable SMT sharing; neither condition is established. Four highmem workers use the conservative 12-GiB plan. Ten/twenty-worker reserved designs exceed trial quota. Running more processes on the same eight vCPUs is not equivalent to obtaining more CPU capacity.

At full configured limits, aggregate native optimize wall time is 100 hours; aggregate worker wall time is about 110 hours. Consumed CPU-hours are not identical to either number; the short-process observation suggests roughly one CPU equivalent during active work, not an exact current measurement. Billed reserved vCPU-hours equal vCPU × VM-hours: the four-worker recommended design reserves 8×27.75=222 vCPU-hours despite only four primary solver threads. The two-per-worker allocation allows for SMT/OS/headroom; it is not a solver threading request.

### Fixed-work speed sensitivity, four-worker recommendation

eta=0.90 is a **model assumption**, not a measured efficiency. Includes the same disk/IP/$1 allowance:

| Cloud speed s | Fixed-work time, p=4, efficiency=0.9 | Cost VND | Meets 50h? |
|---:|---:|---:|---|
| 0.5× | 61.36 h | 623,469 | No |
| 0.75× | 40.99 h | 425,147 | Yes, conditional |
| 1× | 30.81 h | 325,986 | Yes, conditional |
| 1.5× | 20.62 h | 226,826 | Yes, conditional |
| 2× | 15.53 h | 177,245 | Yes, conditional |

For fixed work, four workers need s×eta ≥ 27.5/49.75 ≈ 0.553 to meet 50h. With eta=0.9, s must be ≥0.614. A stronger acceptance gate is measured s≥0.75 and eta≥0.9, giving about 41h. Three-worker bundle scheduling needs s×eta ≥38.5/49.75 ≈0.774, leaving less safety margin.

Scaling stops helping after 20 instance bundles without splitting repetitions. Increasing p from 10 to 20 saves only 5.5 nominal hours and requires another 20 reserved vCPUs in this design, not more trial credit alone. With eight logical CPUs and typically about four physical cores, throughput at p>4 is uncertain; p>8 one-thread CPU-bound workers introduces explicit CPU oversubscription. Measure throughput, not just per-process CPU percentages.

## D. Infrastructure and current account access

### Verified account state

The user-opened GCP Console was read on 21 October 2026. It explicitly shows **Free Trial**, **7,897,351 VND remaining**, and **expiry 20 November 2026** (banner: 29 days). No account/project/billing identifiers or credentials are recorded here. The project quota page did not finish loading, so regional/family quotas, API enablement and Spot allocation were **not** account-verified. The local `gcloud` CLI is not installed. No service was enabled to inspect it.

[Free Trial terms](https://cloud.google.com/terms/free-trial) limit concurrent Compute Engine usage to eight cores; [trial documentation](https://docs.cloud.google.com/free/docs/free-cloud-features#during-free-trial) disallows quota increases while in non-billable trial status. Treat the documented limit as eight concurrent vCPUs for planning, subject to any lower actual quota. A VM being listed publicly is not proof that this project can create it.

| Service/configuration | Assessment under this account |
|---|---|
| E2 on-demand up to 8 vCPU, including highmem-8 | Within published trial CPU ceiling; actual regional quota/capacity must still be checked |
| N2 / C2 | CPU-only families exist in proposed regions; family quota may be zero and cannot be raised in trial; not confirmed accessible |
| Batch | No bypass of Compute Engine quota; API enablement, IAM and actual allocation still unverified |
| Spot | Public docs do not make always-free Compute Engine eligibility equivalent to Welcome-credit coverage. Always-free Spot exclusion is not by itself a ban on trial credit. Actual Spot quota/creation and credit eligibility must be confirmed; not assumed available |
| 10 / 20 reserved workers | Need Paid account and sufficient total/family/IP quota; not feasible as proposed under the current eight-vCPU trial ceiling |
| GPU | Trial restriction and no demonstrated benefit; excluded |

Upgrading to Paid is **not authorized**. It retains unused credit until its original expiry but enables charges beyond credit. Credit expiry and spending limits are separate constraints.

### Architecture options

| Option | Benefits | Costs/risks | Recommendation |
|---|---|---|---|
| A: one VM, external-process pull queue | Simple; one disk/IP; one dependency install | Shared RAM/cache; isolate working directories; controller must recover jobs | Preferred for four workers |
| B: multiple VMs | Failure/memory isolation; simple per-VM logs | More boot disks/IPs and startup; higher quota footprint | Useful after quota confirmation, especially heterogeneous memory |
| C: Google Cloud Batch | Managed task array/retries and concurrency | Packaging/IAM/quotas; retry semantics and partial state still need design | Good if many reruns; not necessary for one coursework batch |
| D: Spot | Lower hourly rate | Capacity/preemption risk, no SLA; partial native state cannot resume | Optional after on-demand pilot and recovery test, not default for deadline |

[Batch pricing](https://cloud.google.com/batch/pricing) adds no orchestration service fee; VM/disk/network/log charges remain. [Batch quotas](https://docs.cloud.google.com/batch/quotas) still apply. Prefer Ubuntu LTS or Debian standard images, no premium image/GPU/license charge.

## E. Prices and financial breakdown

### Verified list prices

On-demand USD per VM-hour, checked 21 October 2026, from the official [general-purpose pricing page](https://cloud.google.com/products/compute/pricing/general-purpose) and [compute-optimized page](https://cloud.google.com/products/compute/pricing/compute-optimized). Regional rows were extracted from the pages' embedded pricing data; the default visible table alone is Iowa. No old blog price was used.

| Machine | vCPU / GiB | Iowa USD/h | Singapore USD/h |
|---|---:|---:|---:|
| e2-standard-2 | 2 / 8 | 0.06701142 | 0.08266614 |
| e2-standard-4 | 4 / 16 | 0.13402284 | 0.16533228 |
| e2-standard-8 | 8 / 32 | 0.26804568 | 0.33066456 |
| e2-highmem-2 | 2 / 16 | 0.09039966 | 0.11151366 |
| e2-highmem-4 | 4 / 32 | 0.18079932 | 0.22302732 |
| e2-highmem-8 | 8 / 64 | 0.36159864 | 0.44605464 |
| n2-standard-8 | 8 / 32 | 0.38847200 | 0.47922400 |
| c2-standard-8 | 8 / 32 | 0.41761600 | 0.51516800 |

C2 is an explicit compute-optimized comparator, not a claim that older C2 is faster than Apple M4. N2 provides a different CPU platform/performance profile. Most x86 vCPUs are hardware threads, not Apple performance cores; see [CPU platforms](https://docs.cloud.google.com/compute/docs/cpu-platforms). Against e2-standard-8 of equal RAM, N2 and C2 need about 1.45× and 1.56× fixed-work speed respectively to offset compute price alone. For budget-defined runs, a faster family instead needs a measurable solution-quality benefit. Singapore E2 costs about 23.4% more; proximity to Vietnam gives little benefit once small input files are local.

[Spot prices](https://cloud.google.com/spot-vms/pricing), same verification date: e2-highmem-8 is $0.216976/h Iowa, $0.267696/h Singapore. e2-standard-8 is $0.160848/h Iowa, $0.198448/h Singapore. Do not apply a generic “up to 91%” reduction to this bill; the current E2 rows here imply roughly 40% off compute.

Exchange conversion uses Vietcombank's USD **sell** rate **26,070 VND/USD**, official XML timestamp **21 October 2026 10:54:04**: [Vietcombank rate board](https://www.vietcombank.com.vn/KHCN/Cong-cu-Tien-ich/Ty-gia), [official XML feed](https://portal.vietcombank.com.vn/Usercontrols/TVPortal.TyGia/pXML.aspx?b=10). This is a budgeting conversion, not Google's VND SKU exchange rate or a promise of bank card settlement rate.

### Formula and itemization

    Compute = Σ_VM hourly_rate × billable_hours
    Disk = Σ_VM 50 GiB × regional_disk_rate × hours / 730
    IPv4 = Σ_VM active_external_IP_rate × hours
    Total = Compute + Disk + IPv4 + storage/operations/egress allowance

Use pd-balanced at $0.10/GiB-month Iowa or $0.11 Singapore, from [disk pricing](https://cloud.google.com/compute/disks-image-pricing). Public IPv4 is $0.005/h on-demand or $0.0025/h Spot from [network pricing](https://cloud.google.com/vpc/network-pricing). No NAT gateway is modeled; using one adds separate charges. Disks left attached to stopped/deleted VMs can continue billing unless deleted.

Tables include a **$1/project allowance**, not a verified flat service tariff: plan ≤5 GiB Standard object storage for a month, ≤2 GiB downloaded artifacts and modest API operations. Uploads/standard inbound transfers are generally free; avoid cross-region buckets and repeated image pulls. See [Cloud Storage](https://cloud.google.com/storage/pricing). Keep solver logs on disk and upload artifacts; default [Cloud Logging allowance](https://cloud.google.com/products/observability/pricing) is 50 GiB/project/month, but other workloads may consume it. No paid custom metrics, large registry storage or NAT processing is assumed. If volumes exceed these assumptions, reprice them.

| Scenario | Compute USD/h (VND/h) | Compute USD | Disk USD | IPv4 USD | Total USD | VND/bundle | Credit remaining VND |
|---|---:|---:|---:|---:|---:|---:|---:|
| Lowest-rate baseline | 0.067011 (1,747) | 7.388 | 0.755 | 0.551 | 9.694 | 12,637 | 7,644,618 |
| Two workers | 0.134023 (3,494) | 7.405 | 0.378 | 0.276 | 9.059 | 11,809 | 7,661,171 |
| Conditional minimum: three | 0.180799 (4,713) | 7.006 | 0.265 | 0.194 | 8.465 | 11,034 | 7,676,665 |
| Four, lean RAM | 0.268046 (6,988) | 7.438 | 0.190 | 0.139 | 8.767 | 11,428 | 7,668,793 |
| Recommended: four | 0.361599 (9,427) | 10.034 | 0.190 | 0.139 | 11.363 | 14,812 | 7,601,113 |
| Five, conditional | 0.361599 (9,427) | 8.046 | 0.152 | 0.111 | 9.309 | 12,135 | 7,654,660 |
| Ten: Paid/quota required | 0.903997 (23,567) | 10.170 | 0.771 | 0.562 | 12.503 | 16,298 | 7,571,398 |
| Twenty: Paid/quota required | 1.807993 (47,134) | 10.396 | 0.788 | 0.575 | 12.759 | 16,631 | 7,564,733 |

“Per bundle” means one original instance with ten repetitions; per individual solve is one tenth of that figure. Hourly figures above are compute only; the total includes itemized extras and the shared $1 allowance. Monetary values exclude unverified taxes and bank/FX fees. We have not established this Cloud billing profile's tax treatment; Google Ads VAT rules must not be substituted for Cloud. A **0–10% tax stress allowance** may be used for budgeting, not as a statement of applicable tax law.

Recommended Iowa example: compute $10.034, disk $0.190, IPv4 $0.139, shared allowance $1 → **$11.363 ≈296,238 VND**, 3.75% of credit, about **7,601,113 VND credit left**. Add 20% operational contingency →355,485 VND. An additional hypothetical 10% tax stress on that reserve →391,034 VND. The slower fixed-work scenario s=0.75/eta=0.9 is about425,147 VND before contingency. A 550,000-VND provisional envelope is about7% of current credit.

Singapore highmem-8/four-worker counterpart is about **357,833 VND** before reserves. A Spot counterpart with **20% extra worker/VM time** is about **222,255 VND**, nominal33.25h. Ignoring availability delays, its break-even extra-hours factor versus on-demand is about1.65 including disk/IP. That 20% is a sensitivity assumption, not a measured interruption probability. Lost in-flight work can be up to a whole native run because the current partial checkpoint is not resumable; do not claim only the last 60-second slice is lost.

If credits cover all eligible costs and the account stays non-billable Free Trial, expected **out-of-pocket is0 VND**. The service consumption figures still reduce credit. Under a Paid account, uncovered/excess usage can charge the payment method. Actual tax/credit eligibility needs invoice confirmation. Unused credit expires on the displayed date; it is not cash returned to the user.

Do not leave a VM idle for all29 remaining days: Iowa highmem-8 plus modeled disk/IP alone would cost about$260, approximately6.8 million VND. Budget alerts are notifications, not hard spending caps. Provision only after approval with idle shutdown and explicit disk/IP cleanup.

## F. Recommended deployment architecture — prepared, not deployed

For Step6: one on-demand e2-highmem-8,64GiB,50GiB pd-balanced in an available us-central1 zone; four Linux Julia processes, one solver thread each. Keep native mathematical settings, seeds, ECMP convention and all objective/feasibility tolerances unchanged. Copy the repository into a private per-worker directory; keep inputs read-only within each copy and output prefixes unique. Preinstall/precompile once before timing; isolate mutable scratch/output and avoid concurrent package installation. Use a controller queue, not concurrent calls into one Julia process.

Queue the20 original instance bundles dynamically, ten repetitions each. Store per-run JSON and seed/config/source hashes; upload after each completed run to a same-region bucket and retain local/native logs. Retry missing/failed tasks explicitly; never mark size-limit, infeasible restricted-pool, OOM or stale config as valid completed original-problem experiments. Preserve partial checkpoints as evidence, not as restored solver state. Linux watchdog must count cumulative optimize-call time, distinguish it from wall time, enforce memory safety and label external stops honestly.

Four lean workers on32GiB are an optional later saving of only about68,000VND if all important jobs are measured ≤6GiB. There is little reason to risk memory failures to save that amount before profiling.

For **both Steps6 and9 within28h**, no currently verified configuration is recommended. A nominal design would need12 suitably provisioned workers for300 optimize hours plus10% overhead, with extra deadline margin suggesting16workers; this exceeds the current trial CPU ceiling when reserving independent vCPU capacity. The two-period code's larger resource profile is not yet measured. Prepare that plan only after local tests and explicit account/quota decisions. No VM or dataset is to be created to hide the workload difference.

## G. Validation plan before any cloud approval

1. Finish local time1/Budget implementation and reference tests first. Verify directed arc removal, demand volumes, ECMP and original segment-set symmetric-difference budget with the official checker. Cloud concurrency must not alter the model.
2. Run exact toy regression on local and candidate Linux: full known sorted vector within tolerance. For time-limited SetA pilots, identical routes/objectives are **not** required across hardware: time-bounded heuristics can explore different candidates. Require feasible checker-approved results, identical input/config hashes, matching r coefficients and honest global bounds/gaps.
3. With permission, measure one short representative medium run and one bounded large run on the original machine. Include SetA-20 and the two-period model in memory checks before full sizing. Do not use tiny exact tests as memory estimates for large instances.
4. Only after cloud approval, run the same configuration once on E2; compare cold installation, first compilation, warmed startup, data construction and optimize time separately. Consider N2/C2 only if measured benefit pays for cost or improves deadline-quality goals.
5. Test two concurrent jobs in separate worker copies; then four if RAM safe. Measure eta=(sum solo fixed-work times)/(p × concurrent makespan) for equal fixed-work tests. On time-limited tests compare quality and CPU throughput at the same budget; unchanged elapsed limit is not proof of zero contention.
6. Record GNU time maxRSS/user/system/elapsed, `pidstat -r -u -d -t`, cgroup memory peak, thread counts, disk throughput, output bytes, CPU model and VM billable lifetime. Reject swapping/OOM, resource sharing that degrades the accepted solution-quality target, or projected makespan>deadline. Keep trial quota/capacity as a gate.

**Commands below are a proposed post-approval Linux benchmark, not executed:**

```sh
# In a private worker checkout, after dependency installation/precompilation:
export JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
/usr/bin/time -v -o bench-time.txt julia --project=. scripts/run_experiments.jl   --instances 4 --runs 1 --time-limit 60 --solver highs --threads 1   --splitting ecmp --output results/cloud-bench-04
# Run a separate collection terminal during the process:
pidstat -r -u -d -t -p <JULIA_PID> 1
# Native math regression (short, known answer):
julia --project=. -e 'include("Project_Orange.jl"); include("test/reference.jl")'
```

Record `Threads.nthreads()`, `LinearAlgebra.BLAS.get_num_threads()` and actual native thread counts; the two solvers use OpenBLAS32 libraries as well, so verify environment settings at runtime. Use distinct directories for concurrent commands. Do not run the macOS watchdog unchanged on Linux. If authorized later, an initial ≤2VM-hour benchmark envelope costs roughly$1–3(26,000–78,000VND), conservatively including setup; it is not spent now.

## H. Final recommendation

1. **Cheapest nominal deadline-feasible Step6 option:** three workers on e2-highmem-4, about38.75h/220,686VND, conditional on≤8GiB/job and CPU contention tests. This is not the conservative initial choice.
2. **Best provisional balance:** four workers on e2-highmem-8, about27.75h/296,238VND for budget-defined Step6; reserve350,000–550,000VND. Lean32GiB is conditional on measurements.
3. **Fastest under current trial constraints:** no measured winner; four highmem workers are the safe initial candidate, five require validation. Twenty isolated workers could nominally finish Step6 in5.75h for332,618VND, but require a Paid account and at least40reserved vCPUs in this design. Credit alone does not authorize or enable this.
4. **Both experiments in28h:** not established;300native hours exceed what four or eight independent workers can execute in28h at full limits. Preserve the original data/repetitions/limits and revisit after local Steps7–8 validation.
5. **Confidence:** high in arithmetic and read prices/account banner; medium in process-level independence once output is isolated; low-to-medium in projected cloud time and RAM until representative large/two-period measurements. No optimality guarantee is implied.
6. **Next step:** complete local correctness/resource tests and confirm actual regional quotas. Prepare a reviewable VM/queue configuration. **Do not create/start a VM, upgrade billing, enable a paid service or launch full experiments without further approval.**

Reproducible numerical inputs and all scenario calculations are retained in `cloud-cost-inputs.json`. No credentials or account identifiers are included.

## Added scope: joint periods 0 and 1, local testing before deployment

The later request adds Step 7/8 implementation and preparation for **both** Step 6 and Step 9. The earlier 27.75-hour estimate covers Step 6 alone. With 20 original instances, ten repetitions, 1800 seconds for Step 6 and 3600 seconds for Step 9, the combined optimize allowance is 300 worker-hours. Adding 10% overhead gives 330 worker-hours. Four workers need about 82.75 hours under the same bundle schedule, not 28 hours.

A conditional combined plan uses **two `e2-highmem-16` VMs**, each 16 vCPUs/128 GiB, with eight independent single-thread solver processes per VM. Reserve up to 12 GiB per job and retain OS/cache headroom. Sort the twenty 11-hour Step 9 bundles and twenty 5.5-hour Step 6 bundles longest first and assign each to the next free worker. Sixteen workers yield a nominal 22-hour makespan plus 0.25-hour setup. Twelve workers yield 27.75 hours and leave little margin. These are scheduling calculations, not measured completion promises.

The verified Iowa `e2-highmem-16` on-demand price is $0.72319728/hour. Two VMs for 22.25 hours, two 50-GiB balanced disks and two ephemeral IPv4 addresses total about **$32.71 = 852,739₫**, excluding tax and negligible output storage/egress. A planning reserve of **1.2 million₫** allows some extra runtime and ancillary cost; it is not a spending authorization. Prices use the same verification date and exchange rate as the preceding tables. Sources: [Compute pricing](https://cloud.google.com/products/compute/pricing/general-purpose), [disk pricing](https://cloud.google.com/compute/disks-image-pricing), [IPv4 pricing](https://cloud.google.com/vpc/network-pricing).

This requires 32 regional vCPUs and an eligible account/quota. The observed Free Trial account cannot support that concurrency under its eight-core restriction. Do not upgrade, request resources, or substitute fewer repetitions automatically. `gcp-experiment-plan.json` is declarative planning data only; it provisions nothing.

Original-machine checks now cover all 20 time-1 data loaders, a complete two-period official-toy oracle, and a 10-second SetA-01 joint-model solve. The latter used 10.0079 optimize seconds / 10.7018 algorithm wall seconds and produced an officially validated solution, MLU 0.929383899821, Budget 23/51, and 1/160 certified stages. Whole-process peak RSS was 1.019 GiB, including compilation and toy checks; peak macOS memory footprint was 0.937 GiB. This is a small-instance short-run measurement and cannot certify the 12-GiB large-job allowance or long-run peak memory. No GCP VM has been created or started. Larger representative memory checks and Linux worker validation remain deployment gates.

Further guarded 5-second local checks completed on SetA-09 and SetA-20. Native peak RSS was 1.215 and 1.521 GiB respectively, with no resource-guard stop. Both solutions passed the official checker. SetA-20 certified 0/4000 stages and had only a zero global bound; short-run feasibility is established, large-instance solution quality and long-run memory remain unverified. See `TIME01.md` for actual optimize/wall timings and the 5-second interruption overrun.
