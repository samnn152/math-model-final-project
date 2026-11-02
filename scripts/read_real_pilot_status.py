"""Canonical monitor fields; never confuse a top-k stage value with MLU."""
import csv
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]/'results/local_setA05_real_budget_20261024'


def read(path):
    try:return json.loads(path.read_text())
    except (OSError,ValueError):return {}


def number(value):
    try:return float(value) if value not in (None,'') else None
    except (ValueError,TypeError):return None


def snapshot():
    state=read(ROOT/'status.json')
    stage=state.get('stage')
    if stage is None:
        stages=state.get('stages',[])
        stage=stages[-1].get('stage',6) if stages else 6
    folder=ROOT/f'step{stage}'/'experiment';base=folder/'setA-05_run-01'
    result=read(base.with_suffix('.json'));solution=read(Path(str(base)+'_solution.json'))
    payload=result or solution
    rows=[]
    csv_path=Path(str(base)+('_stages.csv' if stage==6 else '_cycles.csv'))
    try:rows=list(csv.DictReader(csv_path.open()))
    except OSError:pass
    last=rows[-1] if rows else {}
    mlu=number(result.get('objective',solution.get('mlu')))
    bound=number(result.get('lower_bound',solution.get('lower_bound',solution.get('global_mlu_bound'))))
    gap=number(payload.get('gap'))
    if gap is None and mlu is not None and bound is not None and mlu>0:gap=1-bound/mlu
    prefix=payload.get('lex_completed_stages')
    total=payload.get('lex_total_stages')
    active=payload.get('active_stage',int(last['stage']) if last.get('stage') else None)
    stage_value=number(payload.get('stage_objective',last.get('route_incumbent',last.get('objective'))))
    stage_bound=number(payload.get('stage_lower_bound',last.get('lower_bound',last.get('global_bound'))))
    stage_gap=number(payload.get('stage_gap',last.get('gap')))
    optimize=number(result.get('cpu_time_seconds',last.get('cumulative_optimize_seconds')))
    pricing_path=Path(str(base)+('_pricing.csv' if stage==6 else '_cycles_pricing.csv'))
    pricing_last={}
    try:
        with pricing_path.open() as file:
            for row in csv.DictReader(file):pricing_last=row
    except OSError:pass
    pricing_optimize=number(pricing_last.get('cumulative_optimize_seconds'))
    # A stalled master cycle can contain hundreds of completed pricing solves.
    # Its final row/checkpoint is not written until the whole cycle ends.
    if not result and pricing_optimize is not None:
        optimize=max(optimize or 0.,pricing_optimize)
    return dict(pilot_state=state.get('state'),experiment_step=stage,
        pid=state.get('process_id'),status=payload.get('status','RUNNING'),
        termination=payload.get('termination','RUNNING'),validated=payload.get('validated'),
        mlu=mlu,mlu_lower_bound=bound,mlu_gap_fraction=gap,mlu_gap_percent=100*gap if gap is not None else None,
        certified_stages=prefix,total_stages=total,active_stage=active,
        active_stage_objective=stage_value,active_stage_lower_bound=stage_bound,
        active_stage_gap_fraction=stage_gap,active_stage_gap_percent=100*stage_gap if stage_gap is not None else None,
        optimize_seconds=optimize,optimize_limit_seconds=1800 if stage==6 else 3600,
        wall_seconds=state.get('elapsed_seconds',result.get('wall_time_seconds')),
        rss_bytes=state.get('rss_bytes'),route_columns=number(last.get('route_columns',last.get('pair_columns'))),
        stage_cycle=number(last.get('cycle')),checkpoint=str(base.with_suffix('.json') if result else Path(str(base)+'_solution.json')),
        csv_path=str(csv_path),pricing_csv_path=str(pricing_path),
        latest_pricing_demand=number(pricing_last.get('demand_index')),
        latest_pricing_cycle=number(pricing_last.get('cycle')),
        optimize_accounting_source='final_result' if result else 'latest_completed_master_or_pricing_call')

if __name__=='__main__':print(json.dumps(snapshot(),indent=2))
