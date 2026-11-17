"""Summarize the production D3 Edge continuation experiment without running any model."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

ACTIONS = ['interrupt', 'discard', 'enqueue', 'continue_listening']
PROBES = {'adoption-probe', 'typed-probe', 'capacity-probe'}


def percentile(values, p):
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)] if values else None


def summarize(rows, key):
    expect = 'expected' if key == 'raw' else 'expectedAdopted'
    correct = sum(r.get(key) == r['scenario'][expect] for r in rows)
    tp = sum(r.get(key) == 'continue_listening' and r['scenario'][expect] == 'continue_listening' for r in rows)
    positives = sum(r['scenario'][expect] == 'continue_listening' for r in rows)
    selected = sum(r.get(key) == 'continue_listening' for r in rows)
    return dict(count=len(rows), correct=correct, selectedContinue=selected, expectedContinue=positives,
                continueTP=tp, continuePrecision=tp / selected if selected else None,
                continueRecall=tp / positives if positives else None,
                falseContinue=selected - tp, missedContinue=positives - tp,
                predictions=dict(Counter(r.get(key) or 'invalid' for r in rows)),
                matrix={a: dict(Counter(r.get(key) or 'invalid' for r in rows if r['scenario'][expect] == a)) for a in ACTIONS})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--readout', type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    assert report['model'] == 'd3-edge'
    assert report['sourceHashes'] == report['sourceHashesAfter'], 'Source files changed during the experiment'
    rows = report['rows']
    result = dict(report=args.report.name, reportSHA256=hashlib.sha256(args.report.read_bytes()).hexdigest(),
                  artifact=json.loads(args.artifact.read_text()), groups={})
    for lang in ['en', 'zh-Hans']:
        selected = [r for r in rows if r['scenario']['language'] == lang]
        groups = {'semantic': [r for r in selected if r['scenario']['group'] not in PROBES],
                  'within512': [r for r in selected if r['scenario']['group'] not in PROBES and r['inputTokens'] <= 512]}
        groups.update({g: [r for r in selected if r['scenario']['group'] == g] for g in sorted({r['scenario']['group'] for r in selected})})
        result['groups'][lang] = {}
        for name, group in groups.items():
            native = [r['native']['milliseconds'] for r in group if r.get('native') and not r['native'].get('error')]
            tokens = [r['inputTokens'] for r in group]
            result['groups'][lang][name] = dict(
                raw=summarize(group, 'raw'), adopted=summarize(group, 'adopted'),
                tokensMin=min(tokens) if tokens else None, tokensMax=max(tokens) if tokens else None,
                tokensP50=percentile(tokens, .5), tokensP95=percentile(tokens, .95),
                over512=sum(t > 512 for t in tokens), nativeCompleted=len(native),
                nativeP50MS=percentile(native, .5), nativeP95MS=percentile(native, .95),
                nativeOver250MS=sum(t > 250 for t in native),
                routes=dict(Counter(r['route'] for r in group)),
                failures=dict(Counter(r.get('failure') for r in group if r.get('failure'))))
    result['missedContinue'] = [dict(id=r['scenario']['id'], latest=r['scenario']['latest'], tokens=r['inputTokens'],
                                       raw=r.get('raw'), adopted=r['adopted'], score=(r.get('native') or {}).get('score'))
                                for r in rows if r['scenario']['group'] not in PROBES
                                and r['scenario']['expected'] == 'continue_listening' and r.get('raw') != 'continue_listening']
    result['falseContinue'] = [dict(id=r['scenario']['id'], latest=r['scenario']['latest'], raw=r.get('raw'), adopted=r['adopted'])
                               for r in rows if r['scenario']['group'] not in PROBES
                               and r['scenario']['expected'] != 'continue_listening' and r.get('raw') == 'continue_listening']
    if args.readout:
        diagnostic = json.loads(args.readout.read_text())
        assert diagnostic['inputSHA256'] == result['reportSHA256']
        result['nativeReadout'] = dict(file=args.readout.name, groups={})
        by_id = {r['scenario']['id']: r for r in rows}
        for lang in ['en', 'zh-Hans']:
            selected = [r for r in diagnostic['rows'] if r['language'] == lang and r['group'] not in PROBES]
            compatible = [dict(scenario=by_id[r['id']]['scenario'], raw=r.get('prediction')) for r in selected]
            times = [r['milliseconds'] for r in selected if not r.get('error')]
            result['nativeReadout']['groups'][lang] = dict(
                raw=summarize(compatible, 'raw'), p50MS=percentile(times, .5), p95MS=percentile(times, .95),
                over250MS=sum(t > 250 for t in times),
                errors=sum(bool(r.get('error')) for r in selected),
                continueHits=[r['id'] for r in selected if r.get('prediction') == 'continue_listening'],
                completedProductionComparisons=sum(by_id[r['id']].get('raw') is not None for r in selected),
                completedProductionDisagreements=sum(by_id[r['id']].get('raw') is not None
                    and by_id[r['id']]['raw'] != r.get('prediction') for r in selected))
    with args.output.open('x') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write('\n')
    for lang in result['groups']:
        print(lang, json.dumps(result['groups'][lang]['semantic'], ensure_ascii=False))


if __name__ == '__main__':
    main()
