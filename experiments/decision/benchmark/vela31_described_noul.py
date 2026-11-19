"""Exploratory Vela 3.1 described-noul condition, separate from frozen comparisons."""
import asyncio
import json
import time
from vela31_comparison import HERE, DATA, SUITES, LocalView, digest, save, DATASETS
from hugging_mac_sdk.models.vela.coreai import CoreAIVelaEngine
from hugging_mac_sdk.models.vela.config import VelaInstanceConfig
from hugging_mac_sdk.models.vela.definition import COREAI_LAYOUT
from hugging_mac_sdk.models.vela.utils.packing import DecisionPacker

INPUT = DATASETS / 'decision-vela31-described-noul-input-2026-11-18.json'
OUTPUT = DATA / 'decision-vela31-described-noul-results-2026-11-18.json'


def prepare():
    rows, sources = [], {}
    for suite in ['localized', 'history']:
        path = DATASETS / SUITES[suite]
        sources[path.name] = digest(path)
        for row in json.loads(path.read_text())['rows']:
            if row['variant'] != 'choice_defined' or (suite == 'history' and row['scenario']['historyDepth'] != 0):
                continue
            question = dict(row['question'], type='noul')
            rows.append(dict(suite=suite, variant='noul_defined', scenario=row['scenario'],
                             text=row['request']['text'], question=question))
    save(INPUT, dict(sources=sources, rows=rows), True)


async def run():
    root = HERE.parents[2] / 'Models/Vela31Fast'
    packer = DecisionPacker(root)
    fixture = json.loads(INPUT.read_text())
    engine = CoreAIVelaEngine(
        VelaInstanceConfig(variant='3_1-fast', runtime='coreai', device='cpu', artifact_path=root),
        LocalView(root), COREAI_LAYOUT, model_name='vela3.1-fast')
    report = dict(model='vela31', variant='noul_defined', inputSHA256=digest(INPUT),
                  rows=[], warmup=[], complete=False, tensorParityCases=0)
    save(OUTPUT, report, True)
    try:
        await engine.load(root)
        for item in fixture['rows']:
            q = item['question']
            control = dict(q, type='choice', criteria={'no': q['criteria']['false'], 'yes': q['criteria']['true']})
            a, al = packer.pack(item['text'], q)
            b, bl = packer.pack(item['text'], control)
            assert al == bl and all((a[k] == b[k]).all() for k in a)
            report['tensorParityCases'] += 1
        async def measure(item):
            start = time.perf_counter()
            result = await engine.infer(state=item['text'], questions={'decision': item['question']})
            elapsed = (time.perf_counter()-start)*1000
            p = result['answers']['decision']['noul']
            return dict(item['scenario'], suite=item['suite'], variant='noul_defined',
                        prediction=str(p > .5).lower(), pTrue=p, rawResult=result,
                        inputTokens=result['usage']['input_tokens'], milliseconds=elapsed)
        for suite in ['localized', 'history']:
            for language in ['zh', 'en']:
                first = next(r for r in fixture['rows'] if r['suite']==suite and r['scenario']['locale']==language)
                for _ in range(3):
                    report['warmup'].append(await measure(first))
        for index,item in enumerate(fixture['rows']):
            report['rows'].append(await measure(item))
            if index % 20 == 0:
                save(OUTPUT, report)
                print(f'described noul: {index+1}/{len(fixture["rows"])}', flush=True)
        assert digest(INPUT) == report['inputSHA256']
        report['complete'] = True
        save(OUTPUT, report)
    finally:
        await engine.close()


if __name__ == '__main__':
    import sys
    prepare() if sys.argv[1:] == ['prepare'] else asyncio.run(run())
