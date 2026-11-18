"""User-proposed concise current-conversation/latest-message intent experiment."""
import argparse
import asyncio
import importlib.metadata
import json
import math
from pathlib import Path
import runpy
import sys
import time

from vela31_comparison import DATA, HERE, LocalView, digest, save, sdk_sources, four_metrics

DATE = '2026-11-18'
PREFIX = 'decision-concise-intent'
FORMAT = Path('/Users/devil/Pro/hugging-mac/tmp/originals/d3/edge/bee5e872f75b9c5d1405767bf244a6948b95c0af/d3_format.py')
FORMAT_HASH = '3badfbc70561bb3f5b8ec16a11d2c455b96ddb32caace0a8a54ca102eae1f3fa'
SDK = Path('/Users/devil/Pro/hugging-mac')
SOURCES = {
    'four': 'decision-vela-d3-input-2026-11-17.json',
    'single': 'decision-localized-binary-vela-input-2026-11-17.json',
    'current': 'decision-history-binary-vela-input-2026-11-17.json',
}
WORDS = {
    'zh': dict(dialogue='以下是当前正在进行的对话：', latest='以下是用户发送的最新消息：',
               user='用户', assistant='助手', empty='（无）',
               four='请问用户的意图是什么？', binary='请问用户的意图是否表达打断？',
               categories=['打断', '未说完', '无意义消息', '等待'], boolean=['否', '是']),
    'en': dict(dialogue='The following conversation is currently in progress:',
               latest="The following is the user's latest message:", user='User', assistant='Assistant',
               empty='(None)', four="What is the user's intent?",
               binary="Does the user's intent express an interruption?",
               categories=['Interrupt', 'Unfinished', 'Meaningless message', 'Wait'], boolean=['No', 'Yes']),
}


def file(model, suite, kind):
    return DATA / f'{PREFIX}-{model}-{suite}-{kind}-{DATE}.json'


def render(locale, user, assistant, latest):
    w = WORDS[locale]
    turns = []
    if user:
        turns.append(f"{w['user']}：{user}" if locale == 'zh' else f"User: {user}")
    if assistant:
        turns.append(f"{w['assistant']}：{assistant}" if locale == 'zh' else f"Assistant: {assistant}")
    return w['dialogue'] + '\n' + ('\n'.join(turns) or w['empty']) + '\n\n' + w['latest'] + '\n' + latest


def prepare():
    assert digest(FORMAT) == FORMAT_HASH
    fmt = runpy.run_path(str(FORMAT))
    source_paths = ['Tests/IntegrationTests/DecisionPromptOptimizationTests.swift',
                    'MobileHarness/ModelKit/Language/JEV/D3Decision.swift',
                    'Tests/DecisionBenchmarks/concise_intent_experiment.py']
    hashes = {p: digest(HERE.parents[1] / p) for p in source_paths}
    for suite, source in SOURCES.items():
        items = json.loads((DATA / source).read_text())['rows']
        selected = [r for r in items if r['variant'] == ('utterance_status' if suite == 'four' else 'native_noul')
                    and (suite != 'current' or r['scenario']['historyDepth'] == 0)]
        assert len(selected) == {'four': 54, 'single': 196, 'current': 56}[suite]
        for model in ['shared', 'd3']:
            rows = []
            for item in selected:
                scenario = dict(item['scenario'])
                locale = 'zh' if scenario.get('locale', scenario['language']).startswith('zh') else 'en'
                scenario['locale'] = locale
                if suite == 'four':
                    state = json.loads(item['request']['text'])
                    user = state.get('preceding_user') or ''
                    assistant = state.get('preceding_assistant') or ''
                    if state.get('question_to_user'):
                        assistant = '\n'.join(filter(None, [assistant, state['question_to_user']]))
                    latest = state['utterance']
                elif suite == 'single':
                    user, assistant, latest = '', '', item['request']['text']
                else:
                    state = json.loads(item['request']['text'])
                    turn = state['conversation'][-1]
                    assert turn['is_current_turn']
                    user, assistant, latest = turn['user'], turn['assistant'], state['incoming_user_input']
                text = render(locale, user, assistant, latest)
                for kind in (['choice'] if suite == 'four' else ['noul', 'choice']):
                    q = dict(type=kind, instructions=WORDS[locale]['four' if suite == 'four' else 'binary'])
                    if kind == 'choice':
                        q['criteria'] = dict.fromkeys(WORDS[locale]['categories' if suite == 'four' else 'boolean'])
                    candidates = (fmt['options'](q)[1] if model == 'd3' else
                                  list(q['criteria']) if kind == 'choice' else ['no', 'yes'])
                    actions = ['interrupt', 'continue_listening', 'discard', 'enqueue'] if suite == 'four' else ['false', 'true']
                    row = dict(variant='concise_' + kind, scenario=scenario,
                               request=dict(text=text, instructions=q['instructions'], candidates=candidates, actions=actions),
                               question=q)
                    if model == 'd3':
                        codes = list('ABCD')[:len(candidates)]
                        expected = (f"State:\n{text}\n\nQuestion:\n{q['instructions']}\n\nOptions:\n"
                                    + '\n'.join(f'{a}: {b}' for a,b in zip(codes,candidates))
                                    + '\n\nReply with only the code of the best option.')
                        assert fmt['user_prompt'](text, q, codes) == expected
                    rows.append(row)
            save(file(model, suite, 'input'), dict(sourceFile=source, sourceSHA256=digest(DATA/source),
                 sourceHashes=hashes, formatterSHA256=FORMAT_HASH, rows=rows,
                 note='Waiting maps to enqueue for evaluation; no business-state fields or earlier history.'), True)


def preflight_d3():
    from transformers import AutoTokenizer
    fmt = runpy.run_path(str(FORMAT))
    tok = AutoTokenizer.from_pretrained(HERE / '.local/models/D3Edge', local_files_only=True)
    result = {}
    for suite in SOURCES:
        path = file('d3', suite, 'input')
        rows = []
        for r in json.loads(path.read_text())['rows']:
            ids = tok.apply_chat_template(fmt['messages'](r['request']['text'], r['question'],
                                          list('ABCD')[:len(r['request']['actions'])]),
                                          tokenize=True, return_dict=False, add_generation_prompt=True,
                                          enable_thinking=False)
            rows.append(dict(id=r['scenario']['id'], variant=r['variant'], tokens=len(ids)))
        result[suite] = dict(inputSHA256=digest(path), rows=rows)
        assert max(r['tokens'] for r in rows) <= 512
    save(DATA / f'{PREFIX}-d3-preflight-{DATE}.json', result, True)


async def run(model):
    spec_path = HERE / ('laya-model.json' if model == 'laya' else 'vela31-model.json')
    spec = json.loads(spec_path.read_text())
    root = HERE / '.local/models' / spec['directory']
    for f in spec['files']:
        assert digest(root/f['path']) == f['sha256']
    sources = {__file__: digest(__file__)}
    if model == 'laya':
        wheel = root/spec['hostPackage']['filename']
        assert digest(wheel) == spec['hostPackage']['sha256']
        sys.path.insert(0, str(wheel))
        from laya_artifact_adapter import LayaArtifact
        from laya_comparison import inspect_input
        sources[str(HERE/'laya_artifact_adapter.py')] = digest(HERE/'laya_artifact_adapter.py')
        start = time.perf_counter()
        engine = await LayaArtifact.load(root)
    else:
        from hugging_mac_sdk.models.vela.coreai import CoreAIVelaEngine
        from hugging_mac_sdk.models.vela.config import VelaInstanceConfig
        from hugging_mac_sdk.models.vela.definition import COREAI_LAYOUT
        from hugging_mac_sdk.models.vela.utils.packing import DecisionPacker
        sources.update({str(SDK/p):h for p,h in sdk_sources(SDK).items()})
        packer = DecisionPacker(root)
        start = time.perf_counter()
        engine = CoreAIVelaEngine(VelaInstanceConfig(variant='3_1-fast',runtime='coreai',device='cpu',artifact_path=root),
                                 LocalView(root),COREAI_LAYOUT,model_name='vela3.1-fast')
        await engine.load(root)
    load_ms = (time.perf_counter()-start)*1000
    provenance = dict(specSHA256=digest(spec_path), sourceHashes=sources,
                      device='gpu-debug-enabled' if model == 'laya' else 'cpu',
                      runtimeVersions={n:importlib.metadata.version(n) for n in ['coreai-core','numpy','tokenizers']})
    try:
        for suite in SOURCES:
            path = file('shared', suite, 'input')
            items = json.loads(path.read_text())['rows']
            preflight = []
            for item in items:
                if model == 'laya':
                    detail = inspect_input(engine, item)
                    assert detail['inputComplete']
                else:
                    arrays, labels = packer.pack(item['request']['text'], item['question'])
                    detail = dict(inputTokens=int(arrays['attention_mask'].sum()), inputComplete=True)
                preflight.append(dict(id=item['scenario']['id'], variant=item['variant'], **detail))
            index = {(p['id'],p['variant']):p for p in preflight}
            output = file(model,suite,'results')
            report = dict(model=model,suite=suite,inputSHA256=digest(path),provenance=provenance,
                          loadMilliseconds=load_ms,preflight=preflight,warmup=[],rows=[],complete=False)
            save(output,report,True)

            async def measure(item):
                row = dict(item['scenario'], variant=item['variant'],
                           inputTokens=index[item['scenario']['id'],item['variant']]['inputTokens'])
                start = time.perf_counter()
                try:
                    kwargs = dict(state=item['request']['text'],questions={'decision':item['question']})
                    result = await (engine.predict(**kwargs) if model == 'laya' else engine.infer(**kwargs))
                    row['milliseconds'] = (time.perf_counter()-start)*1000
                    answer = result['answers']['decision']
                    row['rawResult'] = answer
                    if item['question']['type'] == 'noul':
                        p = answer['noul']
                    else:
                        keys = list(item['question']['criteria'])
                        row['prediction'] = item['request']['actions'][keys.index(answer['choice'])]
                        p = answer['probabilities'][keys[1]] if suite != 'four' else None
                    if suite != 'four':
                        assert math.isfinite(p) and 0<=p<=1
                        row.update(pTrue=p,prediction=str(p>.5).lower())
                except Exception as error:
                    row.update(error=f'{type(error).__name__}: {error}',prediction=None,
                               milliseconds=(time.perf_counter()-start)*1000)
                return row

            variants = sorted({i['variant'] for i in items})
            for variant in variants:
                first = next(i for i in items if i['variant']==variant)
                for _ in range(3):
                    r = await measure(first)
                    report['warmup'].append(r)
                    if r.get('error'):
                        save(output,report)
                        raise RuntimeError(r['error'])
            by_key = {(i['scenario']['id'],i['variant']):i for i in items}
            assert len(by_key)==len(items)
            for n, case_id in enumerate(sorted({i['scenario']['id'] for i in items})):
                order = variants[n%len(variants):]+variants[:n%len(variants)]
                for variant in order:
                    report['rows'].append(await measure(by_key[case_id,variant]))
                if n%10==0:
                    save(output,report)
                    print(f'{model}/{suite}: {len(report["rows"])}/{len(items)}',flush=True)
            assert digest(path)==report['inputSHA256']
            assert all(digest(p)==h for p,h in sources.items())
            report['complete']=True
            save(output,report)
            print(f'{model}/{suite}: complete {len(items)}',flush=True)
    finally:
        if model == 'vela31':
            await engine.close()


def summarize():
    metrics = runpy.run_path(str(HERE/'localized_binary_experiment.py'))['metrics']
    groups, rows_by_model, sources = {}, {}, {}
    for model in ['laya','vela31','d3']:
        for suite in SOURCES:
            ip = file('d3' if model=='d3' else 'shared',suite,'input')
            rp = file(model,suite,'results')
            fixture, report = json.loads(ip.read_text()),json.loads(rp.read_text())
            assert report.get('sourcesUnchanged',report.get('complete'))
            assert report['inputSHA256']==digest(ip)
            sources[rp.name]=digest(rp)
            cases={(r['scenario']['id'],r['variant']):r for r in fixture['rows']}
            assert len(report['rows'])==len(cases)
            rows=[]
            for raw in report['rows']:
                item=cases[raw['id'],raw['variant']]
                row=dict(item['scenario'],**{k:v for k,v in raw.items() if k not in item['scenario']})
                assert row['expected']==raw['expected']
                if model=='d3' and suite!='four' and not row.get('error'):
                    p=row['score'] if row['prediction']=='true' else 1-row['score']
                    row.update(pTrue=p,prediction=str(p>.5).lower())
                rows.append(row)
            rows_by_model[f'{model}/{suite}']=rows
            partition='group' if suite=='four' else 'partition'
            for variant in sorted({r['variant'] for r in rows}):
                for part in sorted({r[partition] for r in rows}):
                    for locale in ['all','zh','en']:
                        selected=[r for r in rows if r['variant']==variant and r[partition]==part
                                  and (locale=='all' or r['locale']==locale)]
                        if selected:
                            groups[f'{model}/{suite}/{variant}/{part}/{locale}']=(four_metrics(selected)
                                if suite=='four' else metrics(selected))
    save(DATA/f'{PREFIX}-summary-{DATE}.json',dict(groups=groups,rows=rows_by_model,sources=sources),True)


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('command',choices=['prepare','preflight-d3','run','summarize'])
    p.add_argument('--model',choices=['laya','vela31'])
    args=p.parse_args()
    if args.command=='prepare':prepare()
    elif args.command=='preflight-d3':preflight_d3()
    elif args.command=='summarize':summarize()
    else:asyncio.run(run(args.model))
