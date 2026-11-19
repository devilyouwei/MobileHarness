"""Pair Vela 3.1 results with unchanged historical D3/Vela and same-run Vela 3."""
import json
import runpy
from pathlib import Path
from vela31_comparison import DATA, HERE, SUITES, digest, four_metrics, save, DATASETS

BINARY_METRICS = runpy.run_path(str(HERE / 'localized_binary_experiment.py'))['metrics']
OLD = {
    ('d3', 'four'): 'decision-prompt-optimization-holdout-results-2026-11-16.json',
    ('vela3_historical', 'four'): 'decision-vela-results-2026-11-17.json',
    ('d3', 'binary'): 'decision-binary-d3-results-2026-11-17.json',
    ('vela3_historical', 'binary'): 'decision-binary-vela-results-2026-11-17.json',
    ('d3', 'localized'): 'decision-localized-binary-d3-summary-2026-11-17.json',
    ('vela3_historical', 'localized'): 'decision-localized-binary-vela-summary-2026-11-17.json',
    ('d3', 'history'): 'decision-history-binary-d3-summary-2026-11-17.json',
    ('vela3_historical', 'history'): 'decision-history-binary-vela-summary-2026-11-17.json',
}


def key(row):
    return row['variant'], row['id']


def main():
    sources, reports, groups, paired = {}, {}, {}, {}
    for suite, fixture_name in SUITES.items():
        fixture = json.loads((DATASETS / fixture_name).read_text())
        cases = {(r['variant'], r['scenario']['id']): r for r in fixture['rows']}
        inputs = [item for item in OLD.items() if item[0][1] == suite]
        inputs += [((model, suite), f'decision-vela31-comparison-{model}-{suite}-2026-11-18.json')
                   for model in ['vela31', 'vela3']]
        for (model, _), name in inputs:
            path = DATA / name
            report = json.loads(path.read_text())
            if model in ('vela31', 'vela3'):
                assert report['complete'] and report['inputSHA256'] == digest(DATASETS / fixture_name)
            sources[name] = digest(path)
            rows = []
            for raw in report['rows']:
                if key(raw) not in cases:
                    # D3 has no matching minimal four-class holdout run.
                    assert model == 'd3' and suite == 'four' and raw['variant'] == 'baseline'
                    continue
                item = cases[key(raw)]
                assert raw['expected'] == item['scenario']['expected']
                rows.append(dict(item['scenario'], **{k: v for k, v in raw.items() if k not in item['scenario']}))
            assert len(rows) == len({key(r) for r in rows})
            reports[model, suite] = rows
            for variant in sorted({r['variant'] for r in rows}):
                selected = [r for r in rows if r['variant'] == variant]
                for part in sorted({r.get('group' if suite == 'four' else 'partition', 'all') for r in selected}):
                    values = [r for r in selected if r.get('group' if suite == 'four' else 'partition', 'all') == part]
                    for locale in ['all'] + sorted({r.get('locale', r.get('language')) for r in values}):
                        localized = [r for r in values if locale == 'all' or r.get('locale', r.get('language')) == locale]
                        for depth in (range(5) if suite == 'history' else [None]):
                            subset = [r for r in localized if depth is None or r['historyDepth'] == depth]
                            if subset:
                                group_key = '/'.join(str(x) for x in [model, suite, variant, part, locale, depth])
                                groups[group_key] = four_metrics(subset) if suite == 'four' else BINARY_METRICS(subset)
                                if suite == 'history' and part == 'main':
                                    groups[group_key]['alwaysResolvable'] = BINARY_METRICS([r for r in subset if r['requiredHistory'] == 0])
        new = {key(r): r for r in reports['vela31', suite]}
        for model in ['d3', 'vela3_historical', 'vela3']:
            for variant in sorted({r['variant'] for r in reports[model, suite]}):
                pairs = [(r, new[key(r)]) for r in reports[model, suite]
                         if r['variant'] == variant and r['expected'] != 'unspecified'
                         and (suite != 'four' or r['group'] == 'holdout')]
                paired[f'{model}/{suite}/{variant}'] = dict(
                    count=len(pairs),
                    newCorrectOldWrong=sum(a['prediction'] != a['expected'] and b['prediction'] == b['expected'] for a,b in pairs),
                    oldCorrectNewWrong=sum(a['prediction'] == a['expected'] and b['prediction'] != b['expected'] for a,b in pairs),
                    disagreements=[dict(id=a['id'], expected=a['expected'], old=a['prediction'], new=b['prediction'])
                                   for a,b in pairs if a['prediction'] != b['prediction']])
    equivalence = {}
    for (model, suite), rows in reports.items():
        if suite not in ('localized', 'history'):
            continue
        by_key = {key(r): r for r in rows}
        pairs = [(r, by_key['choice_native_control', r['id']]) for r in rows if r['variant'] == 'native_noul']
        deltas = [abs(a['pTrue']-b['pTrue']) for a,b in pairs if a.get('pTrue') is not None and b.get('pTrue') is not None]
        equivalence[f'{model}/{suite}'] = dict(
            cases=len(pairs), predictionDisagreements=sum(a['prediction'] != b['prediction'] for a,b in pairs),
            maxProbabilityDelta=max(deltas) if deltas else None)
    # Verify exact four-class D3 instruction/state/option identity, not only matching scenario IDs.
    prior = json.loads((DATASETS / 'decision-prompt-optimization-holdout-input-2026-11-16.json').read_text())
    old = {(r['variant'], r['scenario']['id']): r for r in prior['rows']}
    current = json.loads((DATASETS / SUITES['four']).read_text())
    for item in current['rows']:
        identity = item['variant'], item['scenario']['id']
        if identity in old:
            assert item['request'] == old[identity]['request']
    save(DATA / 'decision-vela31-comparison-paired-2026-11-18.json',
         dict(sources=sources, groups=groups, paired=paired, nativeControlEquivalence=equivalence,
              note='D3 and vela3_historical latency are historical; vela31 and vela3 are serial same-host reruns. Busy/idle rows and translated pairs are not independent observations.'), True)


if __name__ == '__main__':
    main()
