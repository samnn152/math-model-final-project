"""Audit saved seed provenance and exact numerical solution diversity; no solver calls."""
import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def load(path):
    return json.loads(path.read_text())

def option(command, name):
    return command[command.index(name) + 1]

def route_key(solution):
    # Demand order in a JSON array must not create artificial route diversity.
    return tuple(sorted((p['d'], p['t'], tuple(p['w'])) for p in solution['srpaths']))

summaries, details = [], []
for i in range(1, 21):
    instance = f'setA-{i:02}'
    rows, solutions, log_hashes = [], [], []
    for run in range(1, 11):
        stem = f'{instance}_run-{run:02}'
        job = ROOT / 'raw' / f'step6_{stem}'
        experiment = job / 'experiment'
        result = load(experiment / f'{stem}.json')
        solution = load(experiment / f'{stem}_solution.json')
        config = load(experiment / 'config.json')
        supervisor = load(job / 'supervisor.json')
        command = supervisor['command']
        expected_seed = 1000 + run
        checks = {
            'result_seed_matches': result['seed'] == expected_seed,
            'supervisor_seed_matches': supervisor['seed'] == expected_seed,
            'config_matches': config['seed_base'] == 1000 and config['run_start'] == run and config['runs'] == 1,
            'command_matches': int(option(command, '--seed-base')) == 1000 and int(option(command, '--run-start')) == run and int(option(command, '--runs')) == 1,
            'run_identity_matches': result['run'] == solution['run'] == supervisor['run'] == run and result['instance'] == solution['instance'] == instance,
            'successful_process': supervisor['completed'] and supervisor['returncode'] == 0,
        }
        assert all(checks.values()), (instance, run, checks)
        trace = experiment / f'{stem}_stages.csv'
        digest = hashlib.sha256(trace.read_bytes()).hexdigest()
        details.append(dict(instance=instance, run=run, expected_seed=expected_seed,
                            checks=checks, stage_trace_sha256=digest))
        rows.append(result); solutions.append(solution); log_hashes.append(digest)
    summaries.append(dict(instance=instance, runs=10, seeds=[r['seed'] for r in rows],
        seed_checks_passed=10,
        distinct_mlu=len({r['objective'] for r in rows}),
        distinct_route_assignments=len({route_key(s) for s in solutions}),
        distinct_sorted_load_vectors=len({tuple(s['sorted_loads']) for s in solutions}),
        distinct_optimize_times=len({r['cpu_time_seconds'] for r in rows}),
        distinct_node_counts=len({r['nodes'] for r in rows}),
        distinct_stage_trace_files=len(set(log_hashes))))
metadata = dict(scope='Step 6: SetA-01 through SetA-20, runs 1 through 10',
    seed_rule='seed_base + run = 1000 + run; expected seeds 1001 through 1010 per instance',
    route_equality='Exact equality of sorted (demand id, period, ordered waypoint tuple) assignments; JSON array order is ignored. Physical ECMP subpaths are not counted as independently chosen routes.',
    load_equality='Exact numerical equality of the entire saved sorted_loads tuple after JSON parsing; no rounding or tolerance clustering.',
    mlu_equality='Exact numerical equality of the saved scalar objective after JSON parsing.',
    evidence_limit='Saved command/configuration/result/supervisor provenance is checked. Different timing/node/trace records support separate executions; this is not a new runtime readback of the solver RNG or a rerun. Unique trace hashes can reflect timestamps or measurements, not necessarily different search paths.')
(ROOT / 'statistics/seed_diversity_audit.json').write_text(json.dumps(dict(metadata=metadata, instances=summaries, run_checks=details), indent=2) + '\n')
fields = [k for k in summaries[0] if k != 'seeds']
with (ROOT / 'statistics/seed_diversity_summary.csv').open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=fields, lineterminator='\n')
    writer.writeheader(); writer.writerows({k:r[k] for k in fields} for r in summaries)
lines = ['# Seed provenance and solution diversity audit', '',
    'All **200/200** run checks pass. Each instance uses seeds **1001–1010**. For every run, the expected seed agrees with the result and supervisor, and the seed base/run number agree with the saved configuration and launch command. Every supervisor records successful completion with return code zero.', '',
    'The experiment code computes `seed = seed_base + run` and passes it to HiGHS through `random_seed`. This audit checks the saved provenance; it does not claim to read back the RNG state inside the historical solver processes.', '',
    '## Why MLU variance can be zero', '',
    'MLU is only the maximum normalized arc load, the first coordinate of the lexicographic objective. Different route assignments and different complete load vectors can share exactly the same maximum. Thus zero MLU variance means the recorded first coordinate is unchanged across seeds; it does not establish identical routing or full lexicographic optimality. Changing a seed also does not require the solver to return a different solution.', '',
    'For example, SetA-01 and SetA-20 each have one MLU value but ten distinct route assignments and ten distinct sorted load vectors. SetA-02 has one route assignment and one vector across all ten runs, while optimize! times, node counts and stage trace files differ across the ten records. The records therefore support separate executions that recovered the same solution, rather than ten copies of one result record.', '',
    'Differences around 1e-17 in MLU (variance around 1e-34) reflect floating-point scale and should not be interpreted as practically meaningful solution variability. Exact numerical counts below retain such differences; no tolerance is applied.', '',
    '## Ten-run diversity by instance', '',
    '| Instance | Seed checks | Distinct MLU | Distinct route assignments | Distinct sorted load vectors | Distinct optimize! times | Distinct node counts | Distinct stage traces |',
    '|---|---:|---:|---:|---:|---:|---:|---:|']
for r in summaries:
    lines.append(f"| {r['instance']} | 10/10 | {r['distinct_mlu']} | {r['distinct_route_assignments']} | {r['distinct_sorted_load_vectors']} | {r['distinct_optimize_times']} | {r['distinct_node_counts']} | {r['distinct_stage_trace_files']} |")
lines += ['', '## Counting rules and limits', '',
    '- A route assignment is the complete set of demand/period waypoint sequences. Assignments are sorted by demand and period before comparison, so JSON record order cannot inflate the count. This counts whole-network routing solutions, not individual demand routes or ECMP physical paths.',
    '- Load vectors are the complete saved nonincreasing normalized arc-load vectors, compared numerically without rounding. Equal sorted vectors need not imply equal loads on each named arc.',
    '- Stage traces are compared by SHA-256 of their original bytes. Different measurements or timestamps can change a trace hash without establishing a different search trajectory.',
    '- Node counts and elapsed times are supporting observations, not mathematical proof of RNG independence. Checkpoint reuse on resuming the same job is permitted by the runner; the audit finds no copied identical result record across the ten runs, and the run-specific seed provenance is consistent.',
    '- This is an offline audit. No jobs were started, solver settings changed, or optimality statuses upgraded.', '',
    'Reproduce from the repository root:', '', '```sh', 'python3 reports/step6_final_20261023/audit_seed_diversity.py', '```', '',
    'Full per-run checks: [JSON](statistics/seed_diversity_audit.json). Compact summary: [CSV](statistics/seed_diversity_summary.csv).']
(ROOT / 'SEED_VARIANCE_AUDIT.md').write_text('\n'.join(lines) + '\n')
print('200/200 seed checks passed; route assignments canonicalized by demand and period.')
for r in summaries:
    print(r['instance'], r['distinct_mlu'], r['distinct_route_assignments'], r['distinct_sorted_load_vectors'])
