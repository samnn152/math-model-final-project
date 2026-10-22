#!/usr/bin/env python3
"""Summarize the existing batch without importing Julia or touching solver processes."""
import datetime
import json
import math
import os
import statistics
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(os.environ.get('ORANGE_RESULTS_ROOT','/opt/orange/results/one_pass'))
REPORTS = Path('/opt/orange/results/monitor')

def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}

def latest_sample(path):
    try:
        with path.open('rb') as stream:
            stream.seek(max(0, path.stat().st_size - 8192))
            lines = stream.read().splitlines()
        return json.loads(lines[-1]) if lines else {}
    except (OSError, ValueError):
        return {}

def number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)

def fmt(value):
    return f"{value:.5g}" if number(value) else 'NA'

def planned_jobs():
    plan=read_json(ROOT/'cloud-config.json').get('plan',{})
    runs=plan.get('runs',1);shards=plan.get('shards',1);index=plan.get('shard_index',0)
    records=[(stage,instance,run) for stage in (9,6) for instance in range(20,0,-1) for run in range(1,runs+1)]
    return [dict(stage=stage,instance=instance,run=run,
                 job=f'step{stage}_setA-{instance:02d}'+(f'_run-{run:02d}' if 'runs' in plan else ''))
            for i,(stage,instance,run) in enumerate(records) if i%shards==index]

def analyze_results(completed, failed, active, terminal):
    rows = []
    for summary in completed + failed:
        directory = ROOT / summary['job']
        row = read_json(directory / 'experiment' / f"setA-{summary['instance']:02d}_run-{summary.get('run',1):02d}.json")
        row = {k: v for k, v in row.items() if k not in ('sorted_loads_json', 'sorted_loads', 'srpaths')}
        row.update(job=summary['job'], stage=summary['stage'], supervisor_completed=summary.get('completed', False),
                   process_wall_seconds=summary.get('wall_seconds'),
                   peak_rss_gib=max(summary.get('sampled_tree_peak_rss_bytes', 0), summary.get('observed_process_hwm_bytes', 0)) / 1024**3)
        if number(row.get('cpu_time_seconds')) and number(row.get('process_wall_seconds')):
            row['optimize_fraction'] = row['cpu_time_seconds'] / row['process_wall_seconds'] if row['process_wall_seconds'] > 0 else None
        gap = row.get('gap')
        row['mlu_gap_10pct_met'] = row.get('validated') is True and number(gap) and 0 <= gap <= .10
        row['lex_certified'] = (row.get('validated') is True and row.get('status') == 'Optimal'
                                and number(row.get('lex_total_stages')) and row['lex_total_stages'] > 0
                                and row.get('lex_completed_stages') == row['lex_total_stages'])
        rows.append(row)
    notes = [f"Nghiệm hợp lệ: {sum(r.get('validated') is True for r in rows)}/{len(rows)}; "
             f"MLU gap <=10%: {sum(r['mlu_gap_10pct_met'] for r in rows)}; "
             f"chứng nhận toàn bộ từ điển: {sum(r['lex_certified'] for r in rows)}."]
    weak = sum(number(r.get('gap')) and r['gap'] >= .999999 for r in rows)
    if weak:
        notes.append(f"{weak} job có gap MLU 100%: cận chưa đủ mạnh để chứng nhận gần tối ưu; không có nghĩa nghiệm sai hoặc cách tối ưu 100%.")
    slow = sum(number(r.get('optimize_fraction')) and r['optimize_fraction'] < .5 and r.get('termination') == 'SEARCH_WALL_LIMIT' for r in rows)
    if slow:
        notes.append(f"{slow} job chạm SEARCH_WALL_LIMIT và optimize! chiếm dưới 50% wall time; không được ghi là đã giải đủ toàn bộ limit optimize!.")
    if failed:
        notes.append('Có job thất bại/dừng bảo vệ: kiểm tra supervisor; không coi các job chưa chạy là hoàn thành.')
    current = []
    for item in active:
        solution = next(iter(sorted((ROOT / item['job'] / 'experiment').glob('*_solution.json'))), None)
        checkpoint = read_json(solution) if solution else {}
        gap = checkpoint.get('gap')
        if not number(gap):
            objective = checkpoint.get('mlu', checkpoint.get('objective'))
            bound = checkpoint.get('global_mlu_bound', checkpoint.get('lower_bound'))
            gap = 1 - bound / objective if number(bound) and number(objective) and objective > 0 else None
        current.append(dict(job=item['job'], wall_seconds=item.get('elapsed_seconds'),
                            rss_gib=item.get('tree_rss_bytes', 0) / 1024**3,
                            checkpoint_validated=checkpoint.get('validated'), objective=checkpoint.get('mlu', checkpoint.get('objective')),
                            gap=gap, lex_completed_stages=checkpoint.get('lex_completed_stages'), lex_total_stages=checkpoint.get('lex_total_stages')))
    # Stage-specific medians are descriptive estimates; unobserved stages use nominal budgets.
    config=read_json(ROOT/'cloud-config.json')
    plan=config.get('plan',{})
    workers={stage:plan.get('stage_workers',{}).get(str(stage),plan.get('workers',2)) for stage in (6,9)}
    estimates, assumptions = {}, []
    for stage, nominal in ((6, 1800), (9, 3600)):
        durations = [r['process_wall_seconds'] for r in rows if r['stage'] == stage and r.get('supervisor_completed') and number(r.get('process_wall_seconds'))]
        estimates[stage] = statistics.median(durations) if durations else nominal * 1.15
        if not durations:
            assumptions.append(f"Step {stage} chưa có mẫu: giả định limit +15% overhead")
    elapsed = {x['job']: x.get('elapsed_seconds', 0) for x in active}
    finished = {r['job'] for r in rows}
    hours=0.
    for job in planned_jobs():
        stage,name=job['stage'],job['job']
        if name in finished:continue
        duration=estimates[stage]
        residual=max(duration-elapsed[name],.1*duration) if name in elapsed else duration
        hours+=residual/workers[stage]/3600
    eta = 'Batch đã kết thúc; xem outcome và số job hoàn thành.' if terminal else f"Ước lượng còn {hours:.1f} giờ (Step9: {workers[9]} worker, Step6: {workers[6]} worker); khoảng {hours * .8:.1f}–{hours * 1.3:.1f} giờ chỉ là kịch bản, không bảo đảm."
    if assumptions:
        eta += ' ' + '; '.join(assumptions) + '.'
    tables={}
    for stage in (6,9):
        grouped={}
        for row in rows:
            if row['stage']==stage:grouped.setdefault(row.get('instance',row['job']),[]).append(row)
        lines=[]
        for instance,group in sorted(grouped.items()):
            objectives=[r['objective'] for r in group if r.get('validated') and number(r.get('objective'))]
            gaps=[r['gap'] for r in group if r.get('validated') and number(r.get('gap'))]
            opt=[r['cpu_time_seconds'] for r in group if r.get('validated') and number(r.get('cpu_time_seconds'))]
            sd=fmt(statistics.stdev(objectives)) if len(objectives)>1 else 'NA'
            lines.append(f"{instance} n={len(objectives)}: obj={fmt(statistics.mean(objectives)) if objectives else 'NA'} +/-{sd}, gap={fmt(100*statistics.mean(gaps)) if gaps else 'NA'}%, opt={fmt(statistics.mean(opt)) if opt else 'NA'}s, full-lex={sum(r['lex_certified'] for r in group)}")
        for part in (0,1):
            tables[f'results{stage}_{part+1}']='\n'.join(lines[part*10:(part+1)*10]) or 'Chưa có kết quả.'
    return dict(results=rows, current_quality=current, interpretation=' '.join(notes), eta=eta, **tables)

def main():
    final = '--final' in sys.argv
    state = subprocess.run(['systemctl', 'is-active', 'orange-batch.service'], capture_output=True, text=True).stdout.strip()
    completed, failed, active = [], [], []
    for directory in sorted(ROOT.glob('step*_setA-*')):
        summary = read_json(directory / 'supervisor.json')
        if summary:
            (completed if summary.get('completed') else failed).append(summary)
        else:
            sample = latest_sample(directory / 'memory.jsonl')
            if sample:
                active.append(dict(job=directory.name, **sample))
    expected=len(planned_jobs())
    done = len(completed) == expected
    terminal = final or done or state in ('inactive', 'failed')
    outcome = 'completed' if done else ('stopped_or_failed' if terminal else 'running')
    report = dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  service_state=state, outcome=outcome,campaign=ROOT.name, completed=len(completed), total=expected,vm=subprocess.check_output(['hostname'],text=True).strip(),
                  step6_completed=sum(x.get('stage') == 6 for x in completed),
                  step9_completed=sum(x.get('stage') == 9 for x in completed),
                  active=[] if terminal else active,
                  failures=[{k: x.get(k) for k in ('job', 'reason', 'returncode', 'termination')} for x in failed])
    report.update(analyze_results(completed, failed, report['active'], terminal))
    REPORTS.mkdir(parents=True, exist_ok=True)
    active_text = ', '.join(x['job'] for x in report['active']) or 'none'
    ram_text = ', '.join(f"{x['job']}: {x.get('tree_rss_bytes', 0) / 1024**3:.2f} GiB" for x in report['active']) or 'not active'
    report['summary'] = (f"{report['timestamp']} | {outcome} | service={state} | "
                         f"vm={report['vm']} completed={len(completed)}/{expected} (Step6={report['step6_completed']}, Step9={report['step9_completed']}) | "
                         f"active={active_text} | RAM={ram_text} | failed={len(failed)}")
    report['active_analysis'] = '; '.join(
        f"{x['job']}: RAM={x['rss_gib']:.2f} GiB, checkpoint obj={fmt(x['objective'])}, "
        f"gap={fmt(100*x['gap']) if number(x['gap']) else 'NA'}%, lex={x['lex_completed_stages']}/{x['lex_total_stages']}"
        for x in report['current_quality']) or 'Không có job đang chạy.'
    payload = json.dumps(report, ensure_ascii=False)
    temporary = REPORTS / 'latest.json.tmp'
    temporary.write_text(payload + '\n')
    temporary.replace(REPORTS / 'latest.json')
    with (REPORTS / 'history.jsonl').open('a') as stream:
        stream.write(payload + '\n')
    print(payload, flush=True)
    try:
        with open('/dev/ttyS0', 'w') as serial:
            serial.write('ORANGE_BATCH_STATUS ' + payload + '\n')
    except OSError:
        pass
    credential_path = Path('/etc/orange-monitor/writer.json')
    if credential_path.exists():
        try:
            from google.oauth2 import service_account
            from google.auth.transport.requests import Request
            credentials = service_account.Credentials.from_service_account_file(
                str(credential_path), scopes=['https://www.googleapis.com/auth/logging.write'])
            credentials.refresh(Request())
            entry = dict(logName='projects/gen-lang-client-0358915784/logs/orange-batch-monitor',
                         resource={'type': 'global', 'labels': {'project_id': 'gen-lang-client-0358915784'}},
                         entries=[{'jsonPayload': report, 'severity': 'NOTICE', 'timestamp': report['timestamp']}])
            request = urllib.request.Request('https://logging.googleapis.com/v2/entries:write',
                data=json.dumps(entry).encode(),
                headers={'Authorization': 'Bearer ' + credentials.token, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=20) as response:
                response.read()
            print('Cloud Logging delivery accepted', flush=True)
        except Exception as error:
            print('Cloud Logging delivery failed: ' + type(error).__name__ + ': ' + str(error), flush=True)
    if terminal:
        if credential_path.exists():
            credential_path.unlink()
        subprocess.run(['systemctl', 'stop', 'orange-monitor.timer'], check=False)

if __name__ == '__main__':
    main()
