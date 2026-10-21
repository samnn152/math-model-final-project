"""Independent rational oracles for the official toy's two-period model at budgets 0 and 20."""
import itertools,json,argparse
from fractions import Fraction
from pathlib import Path
from audit_orange_reference import exact_routing,route_loads


def period_columns(net,tm,scenario,t):
    failed={a for event in scenario['interventions'] if event['t']==t for a in event['links']}
    active=[i for i,a in enumerate(net['links']) if a['id'] not in failed]
    working=dict(net,links=[net['links'][i] for i in active]);coeff=exact_routing(working)
    nodes=[n['id'] for n in net['nodes']];columns=[]
    for d in tm['demands']:
        options={};middle=[n for n in nodes if n not in (d['s'],d['t'])]
        for count in range(scenario['max_segments']):
            for inner in itertools.permutations(middle,count):
                path=(d['s'],)+inner+(d['t'],)
                if not all((i,j) in coeff for i,j in zip(path,path[1:])):continue
                local=route_loads(path,Fraction(str(d['v'][t])),working['links'],coeff)
                loads=[Fraction(0)]*len(net['links'])
                for i,value in zip(active,local):loads[i]=value
                options[path]=loads
        columns.append(options)
    return columns,coeff,active


def minimum_vector(columns):
    best=None;chosen=None;count=0
    for combination in itertools.product(*(c.items() for c in columns)):
        vector=tuple(sorted((sum(values,Fraction(0)) for values in zip(*(x[1] for x in combination))),reverse=True))
        count+=1
        if best is None or vector<best:best=vector;chosen=[list(x[0]) for x in combination]
    return dict(sorted_loads=[float(v) for v in best],exact=[str(v) for v in best],paths=chosen,combinations=count)


def audit(fixture):
    net=json.loads((fixture/'toy-net.json').read_text());tm=json.loads((fixture/'toy-tm.json').read_text());scenario=json.loads((fixture/'toy-scenario.json').read_text())
    periods=[period_columns(net,tm,scenario,t) for t in [0,1]]
    individual=[minimum_vector(c[0]) for c in periods]
    # Budget 20 exceeds the maximum 2*D*K=16, so independent optima are jointly optimal.
    assert 2*len(tm['demands'])*scenario['max_segments']<=20
    free=dict(sorted_loads=sorted(individual[0]['sorted_loads']+individual[1]['sorted_loads'],reverse=True),
        proof='Budget 20 is nonbinding; independently optimal period vectors minimize their sorted union.',periods=individual)
    joint=[]
    for d in range(len(tm['demands'])):
        joint.append({path:periods[0][0][d][path]+periods[1][0][d][path] for path in periods[0][0][d] if path in periods[1][0][d]})
    zero=minimum_vector(joint)
    zero['proof']='Budget zero forces equal segment incidence sets. Common cycles can be removed in both periods, leaving an optimal common simple route.'
    coefficients=[]
    for t,(_,coeff,active) in enumerate(periods):
        for (i,j),local in coeff.items():
            loads=[Fraction(0)]*len(net['links'])
            for a,value in zip(active,local):loads[a]=value
            coefficients += [dict(i=i,j=j,a=net['links'][a]['id'],t=t,value=float(value)) for a,value in enumerate(loads)]
    return dict(budget20=free,budget0=zero,coefficients=coefficients)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    fixture=Path(__file__).resolve().parent.parent/'test/fixtures/orange_subject_toy'
    r=audit(fixture);args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(r,indent=2))
    print(json.dumps({k:{'mlu':v['sorted_loads'][0],'top10':v['sorted_loads'][:10]} for k,v in r.items() if k!='coefficients'},indent=2))
