"""Freeze and summarize two independent native noul questions; no App changes."""
import json, hashlib, statistics, argparse
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
DATA=ROOT/'experiments/decision/results'
DATASETS = ROOT / 'experiments/decision/datasets'
PREFIX='decision-multi-noul-2026-11-18'
PROMPTS = json.loads((Path(__file__).resolve().parents[1] / 'datasets/multi-noul-experiment-prompts.json').read_text())
# category, expected interrupt, expected discard, Chinese, English
CASES = json.loads((Path(__file__).resolve().parents[1] / 'datasets/multi-noul-experiment-cases.json').read_text())
def save(p,v):
 if p.exists(): raise FileExistsError(p)
 p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def prepare():
 rows=[]
 for locale in ['zh','en']:
  for i,(category,interrupt,discard,zh,en) in enumerate(CASES):
   incoming=zh if locale=='zh' else en
   turn={'user':'介绍北京的景点。','assistant':'北京有许多景点，比如故宫和'} if locale=='zh' else {'user':'Tell me about Beijing attractions.','assistant':'Beijing has many attractions, including the Forbidden City and'}
   if category=='answer': turn={'user':'你刚才问我去哪个城市。','assistant':'你想去哪个城市？'} if locale=='zh' else {'user':'You asked me which city to visit.','assistant':'Which city would you like to visit?'}
   rows.append(dict(id=f'{locale}-{i:02}',locale=locale,category=category,partition='probe' if interrupt is None else 'main',text=json.dumps({'current_turn':turn,'incoming_user_input':incoming},ensure_ascii=False),interrupt=None if interrupt is None else bool(interrupt),discard=None if discard is None else bool(discard),questions=PROMPTS[locale]))
  for i,(category,interrupt,discard,zh,en) in enumerate(CASES[:4]+[CASES[10],CASES[21],CASES[30],CASES[32]]):
   incoming=en if locale=='zh' else zh
   rows.append(dict(id=f'{locale}-cross-{i}',locale=locale,category=category,partition='cross',text=json.dumps({'incoming_user_input':incoming},ensure_ascii=False),interrupt=bool(interrupt),discard=bool(discard),questions=PROMPTS[locale]))
 save(DATASETS / f'{PREFIX}-input.json',dict(prompts=PROMPTS,rows=rows,note='Frozen synthetic labels. Clarifiable fragments are meaningful. Probes excluded. Cross-language cases are latest-input-only.'))
 print(len(rows),'cases')
def summarize():
 raw=json.loads((DATA/f'{PREFIX}-results.json').read_text()); fixture=json.loads((DATASETS / f'{PREFIX}-input.json').read_text()); byid={r['id']:r for r in fixture['rows']}
 groups={}
 for model in ['d3','vela','vela31','laya']:
  for order in ['interrupt_first','discard_first']:
   for partition in ['main','cross']:
    for locale in ['all','zh','en']:
     rows=[r for r in raw if r['model']==model and r['order']==order and byid[r['id']]['partition']==partition and (locale=='all' or byid[r['id']]['locale']==locale)]
     g={'n':len(rows),'errors':sum('error' in r for r in rows)}
     times=[r['milliseconds'] for r in rows if 'error' not in r]
     g.update(p50=statistics.median(times) if times else None,p95=sorted(times)[max(0,int(len(times)*.95+.999)-1)] if times else None)
     for q in ['interrupt','discard']:
      valid=[r for r in rows if 'error' not in r];tp=tn=fp=fn=0
      for r in valid:
       y=byid[r['id']][q];p=r[q]
       tp+=y and p;tn+=not y and not p;fp+=not y and p;fn+=y and not p
      g[q]=dict(tp=tp,tn=tn,fp=fp,fn=fn,precision=tp/(tp+fp) if tp+fp else None,recall=tp/(tp+fn) if tp+fn else None,falsePositiveRate=fp/(fp+tn) if fp+tn else None)
     g['bothTrue']=sum(r.get('interrupt') is True and r.get('discard') is True for r in rows)
     g['jointCorrect']=sum('error' not in r and all(r[q]==byid[r['id']][q] for q in ['interrupt','discard']) for r in rows)
     groups[f'{model}/{order}/{partition}/{locale}']=g
 paired={}
 for model in ['d3','vela','vela31','laya']:
  a={r['id']:r for r in raw if r['model']==model and r['order']=='interrupt_first'}
  b={r['id']:r for r in raw if r['model']==model and r['order']=='discard_first'}
  paired[model]={q:sum(a[k].get(q)!=b[k].get(q) for k in a) for q in ['interrupt','discard']}
 save(DATA/f'{PREFIX}-summary.json',dict(groups=groups,orderDisagreements=paired,inputSHA256=hashlib.sha256((DATASETS / f'{PREFIX}-input.json').read_bytes()).hexdigest()))
 for k,g in groups.items():
  if '/main/all' in k:print(k,json.dumps(g))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('command',choices=['prepare','summarize']);p.add_argument('--positive',action='store_true');a=p.parse_args();
 if a.positive:
  PREFIX='decision-multi-positive-noul-2026-11-18'
  for locale in ['zh','en']:
   del PROMPTS[locale]['discard']
   PROMPTS[locale]['meaningful']=('用户最新消息是否有可理解的实际交流意义，值得回复或追问？请求、问题、陈述、回答、问候和可澄清的半句话都算有意义；无法理解的乱码、噪声或混乱词语不算。' if locale=='zh' else 'Does the latest user message have understandable communicative meaning and deserve a response or clarification? Requests, questions, statements, answers, greetings and clarifiable fragments are meaningful; unintelligible gibberish, noise or word salad are not.')
 globals()[a.command]()
