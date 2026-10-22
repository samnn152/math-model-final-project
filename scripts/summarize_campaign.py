"""Combine downloaded campaign shards; preserve failures and per-metric sample counts."""
import argparse
import csv
import json
from pathlib import Path
import re
import statistics


def summarize(roots, output):
    records={}
    for root in roots:
        for path in root.rglob('setA-*_run-*.json'):
            if path.name.endswith('_solution.json'):continue
            match=next((re.fullmatch(r'step([69])_setA-(\d+)_run-(\d+)',p.name) for p in path.parents if re.fullmatch(r'step([69])_setA-(\d+)_run-(\d+)',p.name)),None)
            if not match:continue
            stage,instance,run=map(int,match.groups());key=(stage,instance,run)
            row=json.loads(path.read_text())
            if row.get('run')!=run or row.get('seed')!=1000+run:raise ValueError(f'Run/seed identity mismatch: {path}')
            if key in records:raise ValueError(f'Duplicate run identity: {key}')
            row={k:v for k,v in row.items() if k not in ('sorted_loads_json','sorted_loads','srpaths')}
            records[key]=dict(stage=stage,**row)
    output.mkdir(parents=True,exist_ok=True)
    per_run=list(records.values());fields=list(dict.fromkeys(k for r in per_run for k in r))
    with (output/'runs.csv').open('w') as stream:
        writer=csv.DictWriter(stream,fieldnames=fields,lineterminator='\n');writer.writeheader();writer.writerows(per_run)
    summaries=[]
    for stage in (6,9):
        for instance in range(1,21):
            group=[r for (s,i,_),r in records.items() if s==stage and i==instance]
            result=dict(stage=stage,instance=f'setA-{instance:02d}',expected=10,returned=len(group),
                validated=sum(r.get('validated') is True for r in group),
                target_met=sum(r.get('validated') is True and isinstance(r.get('gap'),(int,float)) and 0<=r['gap']<=.10 for r in group),
                full_lex_optimal=sum(r.get('status')=='Optimal' and r.get('lex_completed_stages')==r.get('lex_total_stages') for r in group))
            for metric in ('objective','cpu_time_seconds','gap','nodes','pricing_nodes','lex_completed_stages'):
                values=[r[metric] for r in group if r.get('validated') is True and isinstance(r.get(metric),(int,float))]
                result[metric+'_n']=len(values)
                result[metric+'_mean']=statistics.mean(values) if values else None
                result[metric+'_sd']=statistics.stdev(values) if len(values)>1 else None
            summaries.append(result)
    with (output/'summary.csv').open('w') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(summaries[0]),lineterminator='\n');writer.writeheader();writer.writerows(summaries)
    state=dict(expected_jobs=400,returned=len(records),complete=len(records)==400,
               missing=[dict(stage=s,instance=i,run=r) for s in (6,9) for i in range(1,21) for r in range(1,11) if (s,i,r) not in records])
    (output/'completeness.json').write_text(json.dumps(state,indent=2)+'\n')
    print(json.dumps({k:v for k,v in state.items() if k!='missing'}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('roots',nargs='+',type=Path);parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();summarize(args.roots,args.output)
