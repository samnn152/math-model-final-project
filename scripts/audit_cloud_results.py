"""Audit saved batch records without starting a solver."""
import argparse
import csv
import json
from pathlib import Path


def audit(root, output):
    rows=[]
    for path in sorted(root.glob('step*_setA-*/supervisor.json')):
        supervisor=json.loads(path.read_text())
        stage, instance=supervisor['stage'],supervisor['instance']
        result_path=path.parent/'experiment'/f'setA-{instance:02d}_run-01.json'
        result=json.loads(result_path.read_text()) if result_path.exists() else {}
        solution_path=path.parent/'experiment'/f'setA-{instance:02d}_run-01_solution.json'
        solution=json.loads(solution_path.read_text()) if solution_path.exists() else {}
        objective=result.get('objective');bound=result.get('lower_bound');gap=result.get('gap')
        errors=[]
        if not result.get('validated'):errors.append('unvalidated')
        if result.get('error'):errors.append('runner_error')
        if not supervisor.get('completed'):errors.append('supervisor_failed')
        if objective is None or bound is None or bound>objective+1e-5:errors.append('invalid_bound')
        if objective and bound is not None and gap is not None and abs(gap-max(0,1-bound/objective))>1e-5:errors.append('inconsistent_gap')
        if stage==9 and (result.get('budget_used') is None or result['budget_used']>result['budget']):errors.append('budget_violated')
        if result.get('status')=='Optimal' and result.get('lex_completed_stages')!=result.get('lex_total_stages'):errors.append('false_lex_optimal')
        opt=result.get('cpu_time_seconds',0);wall=supervisor.get('wall_seconds',0)
        accepted=not errors and gap is not None and 0<=gap<=.10
        reasons=list(errors)
        if gap is None or gap>.10:reasons.append('MLU_target_not_certified')
        if result.get('termination')=='SEARCH_WALL_LIMIT' and wall and opt/wall<.5:reasons.append('overhead_dominates')
        row=dict(job=supervisor['job'],stage=stage,instance=instance,status=result.get('status'),termination=result.get('termination'),
                 objective=objective,lower_bound=bound,gap=gap,validated=result.get('validated'),
                 lex_completed=result.get('lex_completed_stages'),lex_total=result.get('lex_total_stages'),
                 optimize_seconds=opt,process_wall_seconds=wall,optimize_fraction=opt/wall if wall else None,
                 peak_rss_gib=max(supervisor.get('sampled_tree_peak_rss_bytes',0),supervisor.get('observed_process_hwm_bytes',0))/1024**3,
                 quality_accepted=accepted,reasons=';'.join(reasons),record_errors=';'.join(errors))
        rows.append(row)
    output.mkdir(parents=True,exist_ok=True)
    with (output/'audit.csv').open('w') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    report={f'step{stage}':dict(jobs=sum(r['stage']==stage for r in rows),
                 valid=sum(r['stage']==stage and r['validated'] for r in rows),
                 mlu_gap_10pct=sum(r['stage']==stage and r['quality_accepted'] for r in rows),
                 record_errors=sum(r['stage']==stage and bool(r['record_errors']) for r in rows)) for stage in (6,9)}
    (output/'audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();audit(args.root,args.output)
