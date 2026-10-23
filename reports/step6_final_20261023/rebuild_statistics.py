"""Rebuild descriptive statistics from the 200 canonical Step 6 result files."""
import csv
import hashlib
import json
import statistics as st
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + '\n')

def describe(values):
    return dict(n=len(values), mean=st.mean(values), sample_variance=st.variance(values),
                sample_sd=st.stdev(values), population_variance=st.pvariance(values),
                minimum=min(values), maximum=max(values), median=st.median(values))

metrics = ['objective', 'lower_bound', 'gap', 'cpu_time_seconds', 'wall_time_seconds',
           'process_wall_seconds', 'nodes', 'lex_completed_stages', 'stage_gap',
           'peak_rss_gib', 'pricing_optimize_seconds', 'mip_optimize_seconds']
clean = json.loads((ROOT / 'runs_clean.json').read_text())
assert len(clean) == 200
assert len({(r['instance'], r['run']) for r in clean}) == 200
out = ROOT / 'statistics'
out.mkdir(exist_ok=True)
raw_out = ROOT / 'raw_json'
raw_out.mkdir(exist_ok=True)
summaries = []
index = []
for i in range(1, 21):
    name = f'setA-{i:02}'
    rows = sorted([r for r in clean if r['instance'] == name], key=lambda r: r['run'])
    assert [r['run'] for r in rows] == list(range(1, 11))
    packed = []
    for row in rows:
        job = ROOT / 'raw' / row['job']
        source = job / 'experiment' / f"{name}_run-{row['run']:02}.json"
        original = json.loads(source.read_text())
        for key in ['objective', 'lower_bound', 'gap', 'cpu_time_seconds', 'nodes', 'status']:
            assert row[key] == original[key], (name, row['run'], key)
        assert row['validated'] and not row['audit_errors']
        solution = job / 'experiment' / f"{name}_run-{row['run']:02}_solution.json"
        assert solution.exists()
        packed.append(dict(run=row['run'], seed=row['seed'], result=original,
                           supervisor=json.loads((job / 'supervisor.json').read_text()),
                           analysis_record=row,
                           solution_path=solution.relative_to(ROOT).as_posix(),
                           result_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
    summary = dict(instance=name, runs=10,
                   dimensions={k: rows[0][k] for k in ['vertices', 'links', 'demands', 'lex_total_stages']},
                   metrics={k: describe([r[k] for r in rows]) for k in metrics},
                   status_counts=dict(Counter(r['status'] for r in rows)),
                   termination_counts=dict(Counter(r['termination'] for r in rows)),
                   validated_runs=sum(r['validated'] for r in rows),
                   mlu_gap_at_most_10pct_runs=sum(r['mlu_gap_10pct_met'] for r in rows),
                   full_lex_certified_runs=sum(r['full_lex_certified'] for r in rows))
    summaries.append(summary)
    write_json(raw_out / f'{name}.json', dict(schema_version=1, instance=name, period=0, runs=packed))
    index.append(dict(instance=name, runs=10, path=f'raw_json/{name}.json'))
metadata = dict(schema_version=1, scope='Step 6, SetA, time 0, 20 instances x 10 runs',
                objective='MLU: first component of the lexicographically sorted normalized arc-load vector; smaller is better',
                variance='sample_variance uses n-1; population_variance uses n; ± denotes sample_sd, not a confidence interval',
                gap='mean of individual max(0, 1 - lower_bound / objective) values; stored as a fraction',
                timing='All times in seconds. cpu_time_seconds sums elapsed optimize! calls, not OS CPU time. wall_time_seconds is runner wall time; process_wall_seconds includes process startup.',
                certification='Original runner numerical certificates retained; feasible solutions independently audited. This package does not independently prove dual bounds.',
                no_pooled_objective='Objectives from different instances are not pooled into a single performance mean.')
write_json(out / 'instance_statistics.json', dict(metadata=metadata, instances=summaries))
write_json(raw_out / 'index.json', dict(metadata=metadata, instances=index))
flat = []
for s in summaries:
    r = dict(instance=s['instance'], runs=s['runs'], **s['dimensions'])
    for metric, stats in s['metrics'].items():
        r.update({f'{metric}_{k}': v for k, v in stats.items() if k != 'n'})
    r.update({k: s[k] for k in ['validated_runs', 'mlu_gap_at_most_10pct_runs', 'full_lex_certified_runs']})
    flat.append(r)
with (out / 'instance_statistics.csv').open('w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=list(flat[0])); w.writeheader(); w.writerows(flat)
lines = ['# Step 6 statistical tables', '', 'Each row summarizes 10 runs. Variance is sample variance (denominator 9); ± is sample SD. Objective is MLU, not the complete lexicographic vector. All 200 full-vector statuses remain **Not Optimal**.', '',
         '| Instance | V | A | D | MLU mean ± SD | MLU sample variance | Best MLU | Mean LB | Gap mean ± SD (%) |',
         '|---|---:|---:|---:|---:|---:|---:|---:|---:|']
for s in summaries:
    m=s['metrics']; d=s['dimensions']; o=m['objective']; g=m['gap']
    lines.append(f"| {s['instance']} | {d['vertices']} | {d['links']} | {d['demands']} | {o['mean']:.9g} ± {o['sample_sd']:.6g} | {o['sample_variance']:.9g} | {o['minimum']:.9g} | {m['lower_bound']['mean']:.9g} | {100*g['mean']:.6g} ± {100*g['sample_sd']:.6g} |")
lines += ['', '## Time and optimization progress', '', 'Times are seconds; nodes and certified-prefix counts are means across runs. A tiny MLU gap does not certify the whole vector.', '',
          '| Instance | optimize! mean ± SD | optimize! variance (s²) | Runner wall mean ± SD | Process wall mean ± SD | Mean nodes | Mean certified stages / total | MLU gap ≤10% |',
          '|---|---:|---:|---:|---:|---:|---:|---:|']
for s in summaries:
    m=s['metrics']; t=m['cpu_time_seconds']; w=m['wall_time_seconds']; p=m['process_wall_seconds']
    lines.append(f"| {s['instance']} | {t['mean']:.2f} ± {t['sample_sd']:.2f} | {t['sample_variance']:.3f} | {w['mean']:.2f} ± {w['sample_sd']:.2f} | {p['mean']:.2f} ± {p['sample_sd']:.2f} | {m['nodes']['mean']:.1f} | {m['lex_completed_stages']['mean']:g} / {s['dimensions']['lex_total_stages']} | {s['mlu_gap_at_most_10pct_runs']}/10 |")
(ROOT / 'STEP6_TABLE.md').write_text('\n'.join(lines) + '\n')
print('Verified 200 canonical results; wrote 20 instance JSON bundles and statistics.')
