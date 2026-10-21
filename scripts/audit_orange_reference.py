"""Exact time-0 oracle for the seven-node example printed in the Orange subject."""
import argparse
import heapq
import itertools
import json
from fractions import Fraction
from pathlib import Path


def exact_routing(net):
    nodes=[n['id'] for n in net['nodes']]
    arcs=net['links']
    outgoing={n:[] for n in nodes};incoming={n:[] for n in nodes}
    for a,link in enumerate(arcs):
        outgoing[link['from']].append(a);incoming[link['to']].append(a)
    coefficients={}
    for target in nodes:
        distances={target:Fraction(0)};queue=[(Fraction(0),target)]
        while queue:
            length,node=heapq.heappop(queue)
            if length!=distances[node]:continue
            for a in incoming[node]:
                link=arcs[a];candidate=length+Fraction(str(link['metric']))
                if link['from'] not in distances or candidate<distances[link['from']]:
                    distances[link['from']]=candidate
                    heapq.heappush(queue,(candidate,link['from']))
        for source in nodes:
            if source not in distances:continue
            flow={n:Fraction(0) for n in nodes};flow[source]=Fraction(1)
            loads=[Fraction(0)]*len(arcs)
            for node in sorted(distances,key=distances.get,reverse=True):
                if node==target or not flow[node]:continue
                eligible=[a for a in outgoing[node] if arcs[a]['to'] in distances and
                    Fraction(str(arcs[a]['metric']))+distances[arcs[a]['to']]==distances[node]]
                assert eligible
                for a in eligible:
                    value=flow[node]/len(eligible)
                    loads[a]+=value;flow[arcs[a]['to']]+=value
            assert flow[target]==1
            coefficients[source,target]=loads
    return coefficients


def route_loads(path,volume,arcs,coefficients):
    return [volume*sum((coefficients[i,j][a] for i,j in zip(path,path[1:])),Fraction(0))/
        Fraction(str(link['capacity'])) for a,link in enumerate(arcs)]


def exhaustive_oracle(fixture):
    net=json.loads((fixture/'toy-net.json').read_text())
    tm=json.loads((fixture/'time0-tm.json').read_text())
    scenario=json.loads((fixture/'time0-scenario.json').read_text())
    coefficients=exact_routing(net);arcs=net['links'];nodes=[n['id'] for n in net['nodes']]
    candidates=[]
    for demand in tm['demands']:
        source,target=demand['s'],demand['t'];middle=[n for n in nodes if n not in (source,target)]
        paths=[]
        for count in range(scenario['max_segments']):
            for waypoints in itertools.permutations(middle,count):
                path=(source,)+waypoints+(target,)
                if all((i,j) in coefficients for i,j in zip(path,path[1:])):
                    paths.append((path,route_loads(path,Fraction(str(demand['v'][0])),arcs,coefficients)))
        candidates.append(paths)
    best=None;best_paths=None;combinations=0
    for choices in itertools.product(*candidates):
        vector=tuple(sorted((sum(values,Fraction(0)) for values in zip(*(c[1] for c in choices))),reverse=True))
        combinations+=1
        if best is None or vector<best:best=vector;best_paths=[c[0] for c in choices]
    arc_index={(a['from'],a['to']):i for i,a in enumerate(arcs)}
    assert coefficients[0,5][arc_index[1,3]]==Fraction(1,2)
    assert coefficients[0,5][arc_index[3,5]]==Fraction(3,4)
    direct=[route_loads((d['s'],d['t']),Fraction(str(d['v'][0])),arcs,coefficients) for d in tm['demands']]
    baseline=max(sum(values) for values in zip(*direct));assert baseline==Fraction(7,16)
    modified=route_loads((0,4,5),Fraction(50),arcs,coefficients)
    figure4=max(a+b for a,b in zip(modified,direct[1]));assert figure4==Fraction(3,8)
    return dict(candidate_routes=[len(p) for p in candidates],combinations=combinations,
        sorted_loads_exact=[str(x) for x in best],sorted_loads=[float(x) for x in best],
        mlu=float(best[0]),baseline_mlu=float(baseline),figure4_mlu=float(figure4),
        srpaths=[dict(d=d,t=0,w=list(path[1:-1])) for d,path in enumerate(best_paths)],
        coefficients=[dict(i=i,j=j,arc=arcs[a]['id'],value=float(v))
            for (i,j),values in coefficients.items() for a,v in enumerate(values)])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    fixture=Path(__file__).resolve().parent.parent/'test/fixtures/orange_subject_toy'
    result=exhaustive_oracle(fixture)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k!='coefficients'},indent=2))
