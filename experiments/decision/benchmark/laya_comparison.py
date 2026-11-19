"""Frozen Decision matrices through the published Laya CoreAI adapter; no App changes."""
import argparse
import asyncio
import importlib.metadata
import json
import math
import platform
import sys
import time

from vela31_comparison import DATA, HERE, SUITES, digest, save, four_metrics, DATASETS

ROOT = HERE.parents[2] / 'Models/LayaMultilingual'


def fixture(suite):
    name = ('decision-vela31-described-noul-input-2026-11-18.json'
            if suite == 'described' else SUITES[suite])
    path = DATASETS / name
    rows = json.loads(path.read_text())['rows']
    if suite == 'described':
        rows = [dict(row, scenario=dict(row['scenario'], sourceSuite=row['suite']),
                     request={'text': row['text'], 'actions': ['false', 'true']}) for row in rows]
    return path, rows


def question(item):
    return item.get('question') or dict(type='choice', instructions=item['request']['instructions'],
                                      criteria=dict(zip('ABCD', item['request']['candidates'])))


def inspect_input(engine, item):
    from laya.common import build_sequence, render_options
    q = engine._internal(question(item))
    ids, markers, options, truncation = build_sequence(
        engine.tok, item['request']['text'], q, engine.max_len, engine.marker_capacity,
        return_stats=True, return_truncation_stats=True)
    texts = render_options(q)
    lengths = [len(engine.tok(' ' + t.replace(engine.tok.mask_token, ' '),
                              add_special_tokens=False)['input_ids']) for t in texts]
    head = engine.tok(f"{q['t']} question: {q['ins'].replace(engine.tok.mask_token, ' ')}",
                      add_special_tokens=False)['input_ids']
    kept_head = markers[0] - 2
    return dict(inputTokens=len(ids), markers=markers, optionTokenLengths=lengths,
                instructionTokens=len(head), instructionTokensUsed=kept_head,
                options=options, truncation=truncation,
                inputComplete=(not truncation['truncated'] and len(markers) == len(texts)
                               and max(lengths) <= 48 and kept_head == len(head)
                               and options['tokens_per_option'] is None))


async def run(args):
    spec = json.loads((HERE / 'laya-model.json').read_text())
    for item in spec['files']:
        if digest(ROOT / item['path']) != item['sha256']:
            raise ValueError(f"Artifact mismatch: {item['path']}")
    wheel = ROOT / spec['hostPackage']['filename']
    assert digest(wheel) == spec['hostPackage']['sha256']
    sys.path.insert(0, str(wheel))
    from laya_artifact_adapter import LayaArtifact
    start = time.perf_counter()
    engine = await LayaArtifact.load(ROOT)
    load_ms = (time.perf_counter()-start)*1000
    provenance = dict(repository=spec['repository'], revision=spec['revision'], device='gpu', specializationDebug=True,
                      platform=platform.platform(), runnerSHA256=digest(__file__),
                      specSHA256=digest(HERE / 'laya-model.json'),
                      runtimeVersions={n: importlib.metadata.version(n) for n in
                                       ['coreai-core', 'numpy', 'torch', 'transformers', 'tokenizers']},
                      hostPackage=spec['hostPackage'], temperature=engine.temperature,
                      adapterSHA256=digest(HERE / 'laya_artifact_adapter.py'),
                      temperatureByOptions=engine.temperature_by_options)
    try:
        for suite in (list(SUITES)+['described'] if args.suite == 'all' else [args.suite]):
            path, items = fixture(suite)
            if args.limit:
                items = items[:args.limit]
            preflight = [dict(variant=i['variant'], id=i['scenario']['id'], **inspect_input(engine, i))
                         for i in items]
            report = dict(model='laya', suite=suite, provenance=provenance, inputFile=path.name,
                          inputSHA256=digest(path), loadMilliseconds=load_ms, preflight=preflight,
                          warmup=[], rows=[], complete=False)
            output = (HERE / '.local' if args.limit else DATA) / f'decision-laya-{suite}-{args.tag}.json'
            save(output, report, True)
            incomplete = [p for p in preflight if not p['inputComplete']]
            if incomplete:
                raise ValueError(f'{suite}: {len(incomplete)} inputs would be truncated; see {output}')
            details = {(p['variant'], p['id']):p for p in preflight}

            async def measure(item):
                row = dict(item['scenario'], variant=item['variant'],
                           inputTokens=details[item['variant'], item['scenario']['id']]['inputTokens'])
                start = time.perf_counter()
                try:
                    result = await engine.predict(state=item['request']['text'],
                                                  questions={'decision': question(item)})
                    row['milliseconds'] = (time.perf_counter()-start)*1000
                    answer = result['answers']['decision']
                    row['rawResult'] = answer
                    if question(item)['type'] == 'noul':
                        p = answer['noul']
                    else:
                        labels = list(question(item)['criteria'])
                        row['prediction'] = item['request']['actions'][labels.index(answer['choice'])]
                        row['score'] = answer['probabilities'][answer['choice']]
                        p = (answer['probabilities'][labels[item['request']['actions'].index('true')]]
                             if suite != 'four' else None)
                    if suite != 'four':
                        if not math.isfinite(p) or not 0 <= p <= 1:
                            raise ValueError(f'Invalid probability: {p}')
                        row.update(pTrue=p, prediction=str(p > .5).lower())
                except Exception as error:
                    row.update(error=f'{type(error).__name__}: {error}', prediction=None,
                               milliseconds=(time.perf_counter()-start)*1000)
                return row

            variants = sorted({i['variant'] for i in items})
            for variant in variants:
                first = next(i for i in items if i['variant'] == variant)
                for _ in range(3):
                    row = await measure(first)
                    report['warmup'].append(row)
                    if row.get('error'):
                        save(output, report)
                        raise RuntimeError(row['error'])
            # Same case order and rotated condition order as the Vela comparison.
            grouped = {}
            for item in items:
                grouped.setdefault(item['scenario']['id'], {})[item['variant']] = item
            for index, case_id in enumerate(sorted(grouped)):
                order = variants[index % len(variants):] + variants[:index % len(variants)]
                for variant in order:
                    if variant in grouped[case_id]:
                        report['rows'].append(await measure(grouped[case_id][variant]))
                if index % 10 == 0:
                    save(output, report)
                    print(f'{suite}: {len(report["rows"])}/{len(items)}', flush=True)
            assert digest(path) == report['inputSHA256']
            assert digest(__file__) == provenance['runnerSHA256']
            report['complete'] = True
            save(output, report)
            print(f'{suite}: complete {len(items)}', flush=True)
    finally:
        # AIModel owns the native session; this standalone process owns its lifetime.
        # The published adapter has no async close contract.
        del engine


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--suite', choices=['all', *SUITES, 'described'], default='all')
    p.add_argument('--tag', default='2026-11-18')
    p.add_argument('--limit', type=int)
    asyncio.run(run(p.parse_args()))
