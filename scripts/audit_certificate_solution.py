"""Recompute saved certificate routes with independent rational ECMP arithmetic."""
import argparse
import json
from fractions import Fraction
from pathlib import Path
from audit_orange_reference import exact_routing, route_loads


def audit(prefix, solution_path):
    net=json.loads(Path(str(prefix)+'-net.json').read_text())
    tm=json.loads(Path(str(prefix)+'-tm.json').read_text())
    scenario=json.loads(Path(str(prefix)+'-scenario.json').read_text())
    saved=json.loads(solution_path.read_text())
    routes={(int(row['d']),int(row['t'])):row['w'] for row in saved['srpaths']}
    periods=2 if any(t==1 for d,t in routes) else 1
    assert len(routes)==periods*len(tm['demands']), 'Missing or duplicate route'
    all_loads=[];paths={};deterministic=[]
    for t in range(periods):
        removed={int(a) for item in scenario['interventions'] if int(item['t'])<=t for a in item['links']}
        active=dict(net,links=[a for a in net['links'] if int(a['id']) not in removed])
        coefficients=exact_routing(active)
        deterministic.append(all(value in (0,1) for values in coefficients.values() for value in values))
        loads=[Fraction(0)]*len(active['links'])
        for d,demand in enumerate(tm['demands']):
            path=[int(demand['s'])]+list(map(int,routes[d,t]))+[int(demand['t'])]
            assert len(path)-1<=scenario['max_segments']
            assert len(set(path))==len(path)
            assert all((i,j) in coefficients for i,j in zip(path,path[1:]))
            contribution=route_loads(path,Fraction(str(demand['v'][t])),active['links'],coefficients)
            loads=[a+b for a,b in zip(loads,contribution)]
            paths[d,t]=set(zip(path,path[1:]))
        by_id={a['id']:value for a,value in zip(active['links'],loads)}
        all_loads.extend(by_id.get(a['id'],Fraction(0)) for a in net['links'])
    budget_used=sum(len(paths[d,0]^paths[d,1]) for d in range(len(tm['demands']))) if periods==2 else 0
    if periods==2:
        budget=next(item['value'] for item in scenario['budget'] if item['t']==1)
        assert budget_used<=budget
    vector=sorted(map(float,all_loads),reverse=True)
    error=max(abs(a-b) for a,b in zip(vector,saved['sorted_loads']))
    assert len(vector)==len(saved['sorted_loads'])
    assert error<=1e-9, error
    assert saved['status']!='Optimal' or saved['lex_completed_stages']==len(vector)
    return dict(valid=True,periods=periods,demands=len(tm['demands']),budget_used=budget_used,
                deterministic_routing_periods=deterministic,
                mlu=vector[0],max_load_error=error,arithmetic='independent exact rational ECMP',
                scope='feasibility and load reconstruction; does not independently prove global bounds')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix',type=Path)
    parser.add_argument('solution',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    result=audit(args.prefix,args.solution)
    if args.output:args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
