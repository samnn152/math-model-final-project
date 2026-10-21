"""Summarize the bounded solver trial without treating log timestamps as exact root timers."""
import argparse
import csv
import json
import math
import re
from pathlib import Path


def number(text):
    try:
        value = float(str(text).replace(',', ''))
        return value if math.isfinite(value) and abs(value) < 1e19 else None
    except (ValueError, TypeError):
        return None


def read_progress(path, solver):
    rows = []
    for line in path.read_text().splitlines():
        if solver == 'scip' and '|' in line:
            fields = [value.strip() for value in line.split('|')]
            if len(fields) >= 17 and fields[0].endswith('s') and fields[1].isdigit():
                rows.append(dict(seconds=number(fields[0][:-1]),nodes=int(fields[1]),
                    iterations=number(fields[3]),cuts=number(fields[10]),bound=number(fields[14])))
        elif solver == 'highs':
            fields = line.split()
            if fields and len(fields[0]) == 1 and fields[0].isalpha():
                fields = fields[1:]
            if len(fields) == 12 and fields[0].isdigit() and fields[3].endswith('%') and fields[-1].endswith('s'):
                rows.append(dict(seconds=number(fields[-1][:-1]),nodes=int(fields[0]),
                    iterations=number(fields[10]),cuts=number(fields[7]),bound=number(fields[4])))
    return rows


def summarize(root):
    metrics = []
    for path in sorted(root.glob('*/*_run-01.json')):
        run = json.loads(path.read_text())
        solver = run['solver']
        stage_path = Path(run['log_file'])
        with stage_path.open(newline='') as stream:
            stages = list(csv.DictReader(stream))
        for stage in stages:
            log = Path(stage['log_file'])
            progress = read_progress(log, solver)
            first = next((row for row in progress if row['iterations'] and row['iterations'] > 0 and row['bound'] is not None), {})
            stats = json.loads(log.with_name(log.stem + '_statistics.json').read_text())
            nodes = number(stage['nodes'])
            closed_at_root = stage['termination'] == 'OPTIMAL' and nodes is not None and nodes <= 1
            detail = dict(instance=run['instance'],solver=solver,stage=int(stage['stage']),
                optimize_seconds=number(stage['optimize_seconds']),
                upper_bound=number(stage['route_incumbent']),lower_bound=number(stage['lower_bound']),
                normalized_gap=number(stage['gap']),nodes=nodes,termination=stage['termination'],
                first_lp_bound_observed=first.get('bound'),
                first_lp_completion_log_seconds=first.get('seconds'),
                first_lp_native_duration_seconds=None,presolve_native_seconds=None,
                root_proof_elapsed_seconds=number(stage['optimize_seconds']) if closed_at_root else None,
                root_status='optimal_at_root' if closed_at_root else ('branching_observed' if nodes is not None and nodes > 1 else 'root_not_certified_complete'),
                first_lp_timing_precision='log display, approximately 0.1 seconds; includes prior work',
                log_file=str(log))
            if solver == 'scip':
                detail['presolve_native_seconds'] = stats.get('timing',{}).get('presolving_time')
                native_root = stats.get('root',{})
                if native_root.get('first_lp_iterations',0) > 0 and number(native_root.get('first_lp_value')) is not None:
                    detail['first_lp_native_duration_seconds'] = native_root.get('first_lp_time')
            else:
                presolve = re.search(r"^\s*([0-9.]+) \(Presolve\)", log.read_text(), re.MULTILINE)
                if presolve:
                    detail['presolve_native_seconds'] = number(presolve.group(1))
            metrics.append(detail)
    if not metrics:
        raise ValueError('No completed checkpoints found')
    (root/'stage_metrics.json').write_text(json.dumps(metrics,indent=2))
    with (root/'stage_metrics.csv').open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(metrics[0]))
        writer.writeheader();writer.writerows(metrics)
    print(json.dumps(metrics,indent=2))
    return metrics


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output_directory',type=Path)
    summarize(parser.parse_args().output_directory.resolve())
