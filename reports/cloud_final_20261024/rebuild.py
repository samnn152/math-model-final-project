"""Rebuild final campaign tables from the archived cloud records; no solver calls."""
import collections,csv,gzip,hashlib,json,math,re,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parent
records=json.loads(gzip.decompress((ROOT/'results.json.gz').read_bytes()))
expected={(s,i,r) for s in (6,9) for i in range(1,21) for r in range(1,11)}
keys=set();runs=[];issues=[]
for record in sorted(records,key=lambda x:x['job']):
 s,i,n=map(int,re.fullmatch(r'step([69])_setA-(\d+)_run-(\d+)',record['job']).groups());r=record['result'];sol=record['solution'];sup=record['supervisor'];key=(s,i,n)
 assert key not in keys;keys.add(key)
 errors=[]
 if (r['instance'],r['run'],r['seed'])!=(f'setA-{i:02d}',n,1000+n):errors.append('identity')
 if not sup.get('completed') or not r.get('validated') or r.get('error'):errors.append('completion_or_validation')
 if not sol or not sol.get('validated'):errors.append('missing_or_unvalidated_solution')
 u,l,g=r.get('objective'),r.get('lower_bound'),r.get('gap')
 if not all(isinstance(v,(int,float)) and math.isfinite(v) for v in (u,l,g)):errors.append('missing_nonfinite_metric')
 elif l>u+1e-7 or abs(g-max(0,1-l/u))>1e-6:errors.append('bound_gap')
 if sol:
  v=sol.get('sorted_loads',[])
  if not v or abs(max(v)-u)>1e-7 or any(a+1e-7<b for a,b in zip(v,v[1:])):errors.append('load_vector')
  if not sol.get('srpaths'):errors.append('missing_routes')
  if s==9 and not (r.get('budget_used') is not None and r['budget_used']<=r['budget'] and sol['budget_used']==r['budget_used']):errors.append('budget')
 full=r.get('status')=='Optimal' and r.get('lex_completed_stages')==r.get('lex_total_stages') and r.get('lex_total_stages',0)>0
 if r.get('status')=='Optimal' and not full:errors.append('false_full_optimal')
 if errors:issues.append(dict(job=record['job'],errors=errors))
 row={k:v for k,v in r.items() if not isinstance(v,(list,dict)) and k not in ('sorted_loads_json','solution_file')}
 row.update(job=record['job'],stage=s,vm=record['vm'],source_path=record['result_path'],process_wall_seconds=sup.get('wall_seconds'),peak_rss_gib=max(sup.get('sampled_tree_peak_rss_bytes',0),sup.get('observed_process_hwm_bytes',0))/2**30,record_consistent=not errors,mlu_target_met=not errors and 0<=g<=.1,full_lex_optimal=full)
 runs.append(row)
assert keys==expected

def write_csv(name,rows):
 fields=list(dict.fromkeys(k for row in rows for k in row))
 with (ROOT/name).open('w') as f:
  w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
write_csv('runs.csv',runs)
metrics=['objective','lower_bound','gap','cpu_time_seconds','wall_time_seconds','process_wall_seconds','nodes','pricing_nodes','lex_completed_stages','peak_rss_gib','budget_used']
summary=[]
for s in (6,9):
 for i in range(1,21):
  group=[r for r in runs if r['stage']==s and r['instance']==f'setA-{i:02d}'];valid=[r for r in group if r['record_consistent']]
  row=dict(stage=s,instance=f'setA-{i:02d}',returned=len(group),valid=len(valid),mlu_target_met=sum(r['mlu_target_met'] for r in group),full_lex_optimal=sum(r['full_lex_optimal'] for r in group),lex_total=group[0]['lex_total_stages'])
  for metric in metrics:
   values=[r[metric] for r in valid if isinstance(r.get(metric),(int,float)) and math.isfinite(r[metric])]
   for label,value in dict(n=len(values),mean=statistics.mean(values) if values else None,sd=statistics.stdev(values) if len(values)>1 else None,variance=statistics.variance(values) if len(values)>1 else None,min=min(values) if values else None,max=max(values) if values else None).items():row[metric+'_'+label]=value
  summary.append(row)
write_csv('instance_statistics.csv',summary)
(ROOT/'instance_statistics.json').write_text(json.dumps(summary,indent=2)+'\n')
overview={f'step{s}':dict(returned=sum(r['stage']==s for r in runs),valid=sum(r['stage']==s and r['record_consistent'] for r in runs),mlu_target_met=sum(r['stage']==s and r['mlu_target_met'] for r in runs),full_lex_optimal=sum(r['stage']==s and r['full_lex_optimal'] for r in runs),termination=dict(collections.Counter(r['termination'] for r in runs if r['stage']==s))) for s in (6,9)}
(ROOT/'audit.json').write_text(json.dumps(dict(expected=400,returned=len(runs),issues=issues,overview=overview),indent=2)+'\n')
lines=['# Kết quả cloud cuối — Step 6 và Step 9','', 'Đã thu đủ **400/400 run**: 20 instance × 10 lần lặp × 2 bước. Đây là batch cũ; không gồm Step 6 v2 hay các pilot sửa chứng nhận local. Không chạy lại solver khi tổng hợp.','', '| Bước | Run có kết quả | Nhất quán qua kiểm tra bản ghi | Gap MLU ≤10% | Optimal toàn bộ từ điển |','|---|---:|---:|---:|---:|']
for s in (6,9):
 o=overview[f'step{s}'];lines.append(f"| Step {s} | {o['returned']} | {o['valid']} | {o['mlu_target_met']} | {o['full_lex_optimal']} |")
lines+=['','`completed` nghĩa là tiến trình kết thúc và lưu kết quả. `TIME_LIMIT` và `SEARCH_WALL_LIMIT` không phải chứng nhận Optimal. MLU là tọa độ đầu tiên; gap MLU bằng 0 không chứng minh tối ưu toàn bộ vector.','', '## Bảng theo instance','', '± là độ lệch chuẩn mẫu (n−1). Gap là trung bình gap từng run, hiển thị %. Không gộp trung bình MLU giữa các instance. Thời gian optimize là tổng thời lượng optimize! đã ghi, không phải thời gian CPU hệ điều hành.','']
for s in (6,9):
 lines += [f'### Step {s}','','| Instance | n | MLU trung bình ± SD | LB TB | Gap TB % | Đạt ≤10% | Optimize TB (s) | Wall tiến trình TB (s) | Prefix min–max / tổng |','|---|---:|---:|---:|---:|---:|---:|---:|---|']
 for r in summary:
  if r['stage']!=s:continue
  lines.append(f"| {r['instance']} | {r['valid']} | {r['objective_mean']:.9g} ± {r['objective_sd']:.3g} | {r['lower_bound_mean']:.9g} | {100*r['gap_mean']:.6g} | {r['mlu_target_met']}/10 | {r['cpu_time_seconds_mean']:.1f} | {r['process_wall_seconds_mean']:.1f} | {r['lex_completed_stages_min']}–{r['lex_completed_stages_max']}/{r['lex_total']} |")
 lines += ['',f"Trạng thái dừng: {overview[f'step{s}']['termination']}.",'']
lines+=['## Phạm vi kiểm tra và dữ liệu','', 'Kiểm tra đủ 400 định danh, mỗi định danh duy nhất, run/seed đúng (1001–1010), runner báo validated, có route và vector tải, MLU khớp max vector tải, thứ tự vector, công thức gap/cận, Budget của Step 9 và tính nhất quán chứng nhận toàn bộ từ điển. Đây là kiểm tra bản ghi; không tái dựng độc lập ECMP từ topology hoặc kiểm chứng lại chứng minh dual.','', 'Các lần recovery có thể dùng revision và điều kiện thực thi khác nhau. Có run bị giới hạn wall trước khi dùng hết ngân sách optimize. Không dùng số liệu này làm benchmark thời gian có kiểm soát. Chọn bản ghi completed có mtime kết quả mới nhất; manifest ghi các bản trùng và đường dẫn nguồn.','', '- [runs.csv](runs.csv): 400 run, số liệu đầy đủ và nguồn gốc.', '- [instance_statistics.csv](instance_statistics.csv), [JSON](instance_statistics.json): n, mean, SD mẫu, phương sai mẫu, min/max cho từng chỉ tiêu.', '- [audit.json](audit.json): kết quả đối soát và trạng thái dừng.', '- [results.json.gz](results.json.gz): 400 kết quả gốc, supervisor và nghiệm đầy đủ (srpaths, sorted_loads).', '- [manifest.json](manifest.json): thời điểm thu, quy tắc chọn bản ghi và SHA-256 nguồn.', '- `raw/*.json.gz`: các bản ghi completed thu từ bốn VM, giữ cả bản trùng để truy vết.', '', 'Dữ liệu nén là JSON UTF-8 gzip; có thể đọc bằng gzip/json của Python. Không cần kết nối cloud để dựng lại bảng:', '', '```sh','python3 reports/cloud_final_20261024/rebuild.py','```','']
(ROOT/'README.md').write_text('\n'.join(lines))
(ROOT/'checksums.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='checksums.json'},indent=2)+'\n')
print(json.dumps(dict(overview=overview,issues=issues),indent=2))
assert not issues,issues
