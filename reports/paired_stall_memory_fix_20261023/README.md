# Paired search stagnation and memory fix — 23 October 2026

Revision: `stall_memory_v1`. The notebook retains the original two-period model, Budget, route admissibility, integrality and lexicographic objective. Its new Pluto section explains actual-ratio walk bounds, fallback pricing and model disposal.

## Diagnosis

The original SetA-05 run repeated over 33,000 stage-2 cycles with only 161 pair columns, unchanged UB 0.3301311698 and global LB 0.3205095800. RSS reached approximately 48 GiB. The old loop rebuilt an LP and MIP each time; dynamic mode skipped the existing diversification branch. This observation identified a search-control problem and motivated explicit native cleanup. It does not on its own prove a specific allocator leak.

## Implementation

- Tighten the same walk relaxation at actual demand traffic ratios when the coarse grid produces no columns. The relaxed domain and safe Budget floor retain the lower-bound direction.
- An uncertified, unchanged pool stays inside demand-pricing fallback instead of repeatedly rebuilding masters. Unrestricted pricing bounds can strengthen the global correction; excluded-pair pricing bounds are never used as global bounds. Demand visits rotate to avoid starving later demands.
- Finalize disposable HiGHS wrappers immediately, invalidate the native pointer, and request collection at sweep boundaries. The cleanup helper is tested for repeated calls.
- Original proof/lock tolerances and all master/pricing mathematical constraints are retained. Allocation/wall/time guards never imply optimality. The `wall_time_limit` override was used only to bound this local pilot; production defaults are unchanged.

## Evidence

The warm-started local SetA-05 pilot (seed 1002, same time-0 warm start as cloud) retained validated MLU **0.20498587519516004**, global MLU bound equal to that value, Budget **0/1**, and **1/792** certified stages. It remained Not Optimal for the full vector. Only three master-cycle records were written, with no unchanged-pool outer-loop rebuild transition. The search used 13.6707 optimize seconds and 74.9093 wall seconds; the explicit 60-second local wall guard can overshoot during model construction. Including startup, the process took 100.7404 seconds and peaked at **1.6409 GiB RSS**.

A separate 400-master build/solve/dispose stress check on SetA-05 stayed at approximately **1.069 GiB RSS**, with only 0.15625 MiB increase between the 20th and 400th model samples. This is evidence for bounded cleanup in that test, not a proof of memory bounds for every long pricing search.

There were **440 passing local assertions** covering time-1 data, original Budget, exhaustive toy references, exact demand pricing, safe actual-ratio lower bounds and disposal. **388 assertions** passed again with the staged notebook on the cloud Linux host. Different assertion totals reflect time-bounded prefix checks and the additional local time-1 suite. A first cold-start diagnostic found a pilot accounting assertion omitted endpoint-bound optimize time; the final pilot correctly includes it. No production formula was changed to satisfy that assertion.

## Cloud rollout

The tested notebook SHA-256 is in `summary.json`. All four VMs received it in source templates and unfinished, inactive private workers. Completed result files were preserved, and active normal jobs were allowed to finish. The old stage-2-looping 48-GiB SetA-05 run 03 was recorded as `INTERRUPTED_FOR_CODE_UPGRADE`, with its logs/checkpoint preserved, then made eligible for one revision-bounded retry. The previously RSS-failed 48-GiB run 02 was also allowlisted. Recovery attempts archive old output directories before a fresh attempt. No completed job is intentionally relaunched. Existing job-ID CAS claims, memory tiers, seeds and full production solve budgets remain in force.

Completed old runs and new-revision runs must be distinguished when analyzing execution times; retaining completed results does not make the historical implementations identical. Full new solutions carry `pair_search_revision`, and every VM has `/opt/orange/recovery/stall-fix-rollout.json` with old/new hashes, skipped workers and interrupted attempts. A successful bounded test does not guarantee completion of all lexicographic stages or a universal 24/48-GiB limit.

## Files

- `summary.json`: compact evidence and revision hash.
- `setA-05_fix_result.json` and `setA-05_fix_solution.json`: complete local result and route/vector payload.
- `setA-05_fix_cycles*.csv`: master and pricing trace.
- `pilot_supervisor.json`: process wall time and sampled peak RSS.
- `master_churn.json`: RSS samples across 400 disposable masters.
- `regression.log`: local reference and disposal checks.
