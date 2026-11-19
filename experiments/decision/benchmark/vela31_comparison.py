"""Paired frozen Decision matrices; experiment-only Vela 3.1 and Vela 3 runners."""
import argparse
import asyncio
import contextlib
import hashlib
import importlib.metadata
import importlib.util
import json
import math
import platform
from pathlib import Path
import runpy
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
DATA = ROOT / 'experiments/decision/results'
DATASETS = ROOT / 'experiments/decision/datasets'
SUITES = {
    'four': 'decision-vela-d3-input-2026-11-17.json',
    'binary': 'decision-binary-input-2026-11-17.json',
    'localized': 'decision-localized-binary-vela-input-2026-11-17.json',
    'history': 'decision-history-binary-vela-input-2026-11-17.json',
}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, obj, first=False):
    with path.open('x' if first else 'w') as output:
        json.dump(obj, output, ensure_ascii=False, indent=2)
        output.write('\n')


def sdk_sources(sdk):
    base = sdk / 'packages/hugging_mac_sdk/src/hugging_mac_sdk'
    paths = list((base / 'models/vela').rglob('*.py')) + [base / 'runtime/coreai.py']
    return {str(p.relative_to(sdk)): digest(p) for p in paths}


class LocalView:
    """An explicit complete decision bundle, without unrelated SDK download selections."""
    def __init__(self, root):
        self.root = root

    def view(self):
        return contextlib.nullcontext(self.root)


async def run(args):
    spec_path = HERE / ('vela31-model.json' if args.model == 'vela31' else 'vela-model.json')
    spec = json.loads(spec_path.read_text())
    root = HERE.parents[2] / 'Models' / spec['directory']
    for item in spec['files']:
        if digest(root / item['path']) != item['sha256']:
            raise ValueError(f"Artifact mismatch: {item['path']}")
    sdk_hashes = sdk_sources(args.sdk)
    provenance = dict(
        repository=spec['repository'], revision=spec['revision'], artifactSpecSHA256=digest(spec_path),
        sdkCommit=subprocess.check_output(['git', '-C', str(args.sdk), 'rev-parse', 'HEAD'], text=True).strip(),
        sdkSourceHashes=sdk_hashes,
        runtimeVersions={name: importlib.metadata.version(name) for name in ['numpy', 'tokenizers', 'coreai-core']},
        platform=platform.platform(), processor=platform.processor(), device='cpu', threads=1,
        runnerSHA256=digest(Path(__file__)),
    )
    started = time.perf_counter()
    if args.model == 'vela31':
        from hugging_mac_sdk.models.vela.coreai import CoreAIVelaEngine
        from hugging_mac_sdk.models.vela.config import VelaInstanceConfig
        from hugging_mac_sdk.models.vela.definition import COREAI_LAYOUT
        engine = CoreAIVelaEngine(
            VelaInstanceConfig(variant='3_1-fast', runtime='coreai', device='cpu', artifact_path=root),
            LocalView(root), COREAI_LAYOUT, model_name='vela3.1-fast')
        await engine.load(root)
        old_context = None
    else:
        module_spec = importlib.util.spec_from_file_location('frozen_vela3', root / 'vela_coreai.py')
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        old_context = module.VelaCoreAI.open(root)
        engine = await old_context.__aenter__()
    load_ms = (time.perf_counter() - started) * 1000
    print(f'{args.model}: loaded in {load_ms:.1f} ms', flush=True)
    try:
        for suite in (SUITES if args.suite == 'all' else [args.suite]):
            input_path = DATASETS / SUITES[suite]
            fixture = json.loads(input_path.read_text())
            items = fixture['rows'][:args.limit] if args.limit else fixture['rows']
            output_path = DATA / f'decision-vela31-comparison-{args.model}-{suite}-{args.tag}.json'
            report = dict(model=args.model, suite=suite, provenance=provenance, inputFile=input_path.name,
                          inputSHA256=digest(input_path), loadMilliseconds=load_ms, warmup=[], rows=[], complete=False)
            save(output_path, report, True)

            async def measure(item):
                request = item['request']
                question = item.get('question') or dict(type='choice', instructions=request['instructions'],
                                                       criteria=dict(zip('ABCD', request['candidates'])))
                row = dict(variant=item['variant'], **item['scenario'])
                start = time.perf_counter()
                try:
                    if args.model == 'vela31':
                        result = await engine.infer(state=request['text'], questions={'decision': question})
                        answer = result['answers']['decision']
                        tokens = result['usage']['input_tokens']
                    else:
                        answer = await engine.predict(request['text'], question)
                        tokens = None
                    elapsed = (time.perf_counter() - start) * 1000
                    if tokens is None:
                        arrays, _ = engine.pack(request['text'], question)
                        tokens = int(arrays['attention_mask'].sum())
                    row.update(rawResult=answer, inputTokens=tokens, milliseconds=elapsed)
                    if question['type'] == 'noul':
                        probability = answer['noul']
                        row.update(pTrue=probability, prediction=str(probability > .5).lower())
                    else:
                        labels = list(question['criteria'])
                        index = labels.index(answer['choice'])
                        row.update(prediction=request['actions'][index], score=answer['probabilities'][answer['choice']])
                        if suite != 'four':
                            probability = answer['probabilities'][labels[request['actions'].index('true')]]
                            row.update(pTrue=probability, prediction=str(probability > .5).lower())
                    if suite != 'four' and not (math.isfinite(row['pTrue']) and 0 <= row['pTrue'] <= 1):
                        raise ValueError('Invalid boolean probability')
                except Exception as error:
                    row.update(prediction=None, error=f'{type(error).__name__}: {error}',
                               milliseconds=(time.perf_counter() - start) * 1000)
                return row

            variants = sorted({item['variant'] for item in items})
            for variant in variants:
                first = next(item for item in items if item['variant'] == variant)
                for _ in range(3):
                    row = await measure(first)
                    report['warmup'].append(row)
                    if row.get('error'):
                        save(output_path, report)
                        raise RuntimeError(row['error'])
            by_key = {(item['scenario']['id'], item['variant']): item for item in items}
            if len(by_key) != len(items):
                raise ValueError('Duplicate fixture identity')
            for i, case_id in enumerate(sorted({key[0] for key in by_key})):
                order = variants[i % len(variants):] + variants[:i % len(variants)]
                for variant in order:
                    if item := by_key.get((case_id, variant)):
                        report['rows'].append(await measure(item))
                if i % 10 == 0:
                    save(output_path, report)
                    print(f'{args.model}/{suite}: {len(report["rows"])}/{len(items)}', flush=True)
            assert digest(input_path) == report['inputSHA256']
            assert sdk_sources(args.sdk) == sdk_hashes, 'SDK changed during experiment'
            report['complete'] = True
            save(output_path, report)
            print(f'{args.model}/{suite}: complete {len(items)}', flush=True)
    finally:
        if old_context:
            await old_context.__aexit__(None, None, None)
        else:
            await engine.close()


def four_metrics(rows):
    labels = ['interrupt', 'discard', 'enqueue', 'continue_listening']
    matrix = {label: {prediction: 0 for prediction in labels + ['error']} for label in labels}
    for row in rows:
        matrix[row['expected']][row['prediction'] if not row.get('error') else 'error'] += 1
    f1 = []
    for label in labels:
        tp = matrix[label][label]
        fp = sum(matrix[other][label] for other in labels if other != label)
        fn = sum(matrix[label].values()) - tp
        f1.append(2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else 0)
    times = sorted(row['milliseconds'] for row in rows)
    return dict(count=len(rows), correct=sum(row.get('prediction') == row['expected'] for row in rows),
                macroF1=statistics.mean(f1), matrix=matrix,
                falseDiscard=sum(row.get('prediction') == 'discard' and row['expected'] != 'discard' for row in rows),
                falseInterrupt=sum(row.get('prediction') == 'interrupt' and row['expected'] != 'interrupt' for row in rows),
                continueTP=matrix['continue_listening']['continue_listening'],
                expectedContinue=sum(matrix['continue_listening'].values()),
                errors=sum(bool(row.get('error')) for row in rows),
                p50MS=statistics.median(times), p95MS=times[math.ceil(len(times)*.95)-1])


def summarize(args):
    common = runpy.run_path(str(HERE / 'localized_binary_experiment.py'))
    groups = {}
    paths = [DATA / f'decision-vela31-comparison-{model}-{suite}-{args.tag}.json'
             for model in ['vela31', 'vela3'] for suite in SUITES]
    for path in paths:
        report = json.loads(path.read_text())
        if not report.get('complete'):
            raise ValueError(f'Incomplete report: {path}')
        suite = report['suite']
        rows = report['rows']
        for variant in sorted({r['variant'] for r in rows}):
            selected = [r for r in rows if r['variant'] == variant]
            partitions = ['holdout', 'diagnostic'] if suite == 'four' else sorted({r.get('partition', 'all') for r in selected})
            for part in partitions:
                values = [r for r in selected if r.get('group' if suite == 'four' else 'partition', 'all') == part]
                for locale in ['all'] + sorted({r.get('locale', r.get('language')) for r in values}):
                    localized = [r for r in values if locale == 'all' or r.get('locale', r.get('language')) == locale]
                    for depth in (range(5) if suite == 'history' else [None]):
                        subset = [r for r in localized if depth is None or r['historyDepth'] == depth]
                        if not subset:
                            continue
                        key = '/'.join(str(x) for x in [report['model'], suite, variant, part, locale, depth])
                        groups[key] = four_metrics(subset) if suite == 'four' else common['metrics'](subset)
    save(DATA / f'decision-vela31-comparison-summary-{args.tag}.json', dict(groups=groups), True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['run', 'summarize'])
    parser.add_argument('--model', choices=['vela31', 'vela3'], default='vela31')
    parser.add_argument('--suite', choices=['all', *SUITES], default='all')
    parser.add_argument('--tag', default='2026-11-18')
    parser.add_argument('--sdk', type=Path, default=Path('/Users/devil/Pro/hugging-mac'))
    parser.add_argument('--limit', type=int)
    args = parser.parse_args()
    asyncio.run(run(args)) if args.command == 'run' else summarize(args)
