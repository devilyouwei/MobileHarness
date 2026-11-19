"""Paired Laya experiment: concise layout with explicit category boundaries."""
import argparse
import asyncio
import copy
import json
import runpy
from pathlib import Path
import concise_intent_experiment as base

OLD = base.PREFIX
base.PREFIX = 'decision-defined-intent'
PROMPTS = json.loads((Path(__file__).resolve().parents[1] / 'datasets/defined-intent-experiment-prompts.json').read_text())


def prepare():
    for suite in base.SOURCES:
        old_path = base.DATASETS / f'{OLD}-shared-{suite}-input-{base.DATE}.json'
        fixture = json.loads(old_path.read_text())
        rows = copy.deepcopy(fixture['rows'])
        for old, row in zip(fixture['rows'], rows):
            prompt = PROMPTS[row['scenario']['locale']]['four' if suite == 'four' else 'binary']
            row['request']['instructions'] = row['question']['instructions'] = prompt
            unchanged = copy.deepcopy(row)
            unchanged['request']['instructions'] = old['request']['instructions']
            unchanged['question']['instructions'] = old['question']['instructions']
            assert unchanged == old
        base.save(base.file('shared', suite, 'input'), dict(
            sourceFile=old_path.name, sourceSHA256=base.digest(old_path),
            experimentSourceSHA256=base.digest(__file__), rows=rows,
            note='Only question instructions changed; variants retain concise names for paired comparison.'), True)


async def run():
    source_hash = base.digest(__file__)
    await base.run('laya')
    assert base.digest(__file__) == source_hash
    for suite in base.SOURCES:
        path = base.file('laya', suite, 'results')
        report = json.loads(path.read_text())
        report['provenance']['sourceHashes'][str(Path(__file__).resolve())] = source_hash
        base.save(path, report)


def summarize():
    metrics = runpy.run_path(str(base.HERE/'localized_binary_experiment.py'))['metrics']
    groups, paired, sources = {}, {}, {}
    for suite in base.SOURCES:
        old_path = base.DATA/f'{OLD}-laya-{suite}-results-{base.DATE}.json'
        new_path = base.file('laya', suite, 'results')
        old, new = [json.loads(p.read_text()) for p in (old_path, new_path)]
        assert old['complete'] and new['complete']
        assert new['inputSHA256'] == base.digest(base.file('shared', suite, 'input'))
        for p in (old_path, new_path):
            sources[p.name] = base.digest(p)
        old_by_key = {(r['id'], r['variant']): r for r in old['rows']}
        assert len(old_by_key) == len(new['rows'])
        paired[suite] = []
        for row in new['rows']:
            previous = old_by_key[row['id'], row['variant']]
            assert previous['expected'] == row['expected']
            paired[suite].append(dict(id=row['id'], variant=row['variant'], expected=row['expected'],
                oldPrediction=previous['prediction'], newPrediction=row['prediction'], error=row.get('error')))
        partition = 'group' if suite == 'four' else 'partition'
        for version, report in [('old',old), ('new',new)]:
            for variant in sorted({r['variant'] for r in report['rows']}):
                for part in sorted({r[partition] for r in report['rows']}):
                    for locale in ['all','zh','en']:
                        selected = [r for r in report['rows'] if r['variant']==variant and r[partition]==part
                                    and (locale=='all' or r['locale']==locale)]
                        if selected:
                            groups[f'{version}/{suite}/{variant}/{part}/{locale}'] = (
                                base.four_metrics(selected) if suite=='four' else metrics(selected))
    base.save(base.DATA/f'{base.PREFIX}-summary-{base.DATE}.json',
              dict(groups=groups,paired=paired,sources=sources,prompts=PROMPTS), True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['prepare','run','summarize'])
    args = parser.parse_args()
    if args.command == 'prepare': prepare()
    elif args.command == 'run': asyncio.run(run())
    else: summarize()
