"""Freeze native Swift adapter readout checks from completed Python experiments."""
import json
from pathlib import Path
from vela31_comparison import DATA, HERE, save, digest

rows=[]
sources={}
for model in ['vela31','laya']:
    root=HERE/'.local/models'/('Vela31Fast' if model=='vela31' else 'LayaMultilingual/macos/wfp16-s512')
    for suite in ['four','single','current']:
        ip=DATA/f'decision-concise-intent-shared-{suite}-input-2026-11-18.json'
        rp=DATA/f'decision-concise-intent-{model}-{suite}-results-2026-11-18.json'
        inputs=json.loads(ip.read_text())['rows']; results=json.loads(rp.read_text())['rows']
        sources[ip.name]=digest(ip);sources[rp.name]=digest(rp)
        lookup={(r['id'],r['variant']):r for r in results}
        for locale in ['zh','en']:
            selected=[r for r in inputs if r['scenario']['locale']==locale and
                      r['scenario'].get('partition',r['scenario'].get('group')) in ['main','holdout']]
            ids=list(dict.fromkeys(r['scenario']['id'] for r in selected))[:3]
            for item in selected:
                if item['scenario']['id'] not in ids:continue
                r=lookup[item['scenario']['id'],item['variant']];q=item['question']
                if q['type']=='noul':value=r['prediction'];score=r['pTrue']
                else:
                    value=r['rawResult']['choice'];score=r['rawResult']['probabilities'][value]
                rows.append(dict(model=model,artifacts=str(root),id=f"{suite}/{r['id']}/{r['variant']}",
                    text=item['request']['text'],instructions=q['instructions'],kind=q['type'],
                    candidates=list(q.get('criteria',{})),prediction=value,score=score))
save(DATA/'decision-swift-adapters-input-2026-11-18.json',dict(sources=sources,rows=rows),True)
print(len(rows),'frozen native comparisons')

# Separate tokenizer evidence isolates host encoding from graph execution differences.
from transformers import AutoTokenizer
root=HERE/'.local/models/LayaMultilingual/macos/wfp16-s512/tokenizer'
tokenizer=AutoTokenizer.from_pretrained(root,local_files_only=True)
spans=[]
for row in rows:
    if row['model']!='laya':continue
    options=(row['candidates'] if row['kind']=='choice' else
             ['false: no, the statement does not hold','true: yes, the statement holds'])
    for text in [row['text'],row['kind']+' question: '+row['instructions']]+[' '+o for o in options]:
        text=text.replace('<mask>',' ')
        spans.append(dict(text=text,ids=tokenizer.encode(text,add_special_tokens=False)))
save(DATA/'decision-laya-swift-token-input-2026-11-18.json',dict(root=str(root.resolve()),rows=spans),True)
