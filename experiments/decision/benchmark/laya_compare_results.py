"""Separate Laya matrix metrics and paired changes against frozen D3/Vela results."""
import json
import runpy

from vela31_comparison import DATA, HERE, SUITES, digest, four_metrics, save, DATASETS

METRICS = runpy.run_path(str(HERE / 'localized_binary_experiment.py'))['metrics']


def main():
    groups, pairs, sources = {}, {}, {}
    for suite in [*SUITES, 'described']:
        path = DATA / f'decision-laya-{suite}-2026-11-18.json'
        report = json.loads(path.read_text())
        assert report['complete']
        assert digest(DATASETS / report['inputFile']) == report['inputSHA256']
        assert all(p['inputComplete'] for p in report['preflight'])
        sources[path.name] = digest(path)
        rows = report['rows']
        assert len(rows) == len({(r['variant'], r['id']) for r in rows})
        for variant in sorted({r['variant'] for r in rows}):
            selected = [r for r in rows if r['variant'] == variant]
            partition = 'group' if suite == 'four' else 'partition'
            for part in sorted({r.get(partition, 'all') for r in selected}):
                values = [r for r in selected if r.get(partition, 'all') == part]
                for locale in ['all'] + sorted({r.get('locale', r.get('language')) for r in values}):
                    localized = [r for r in values if locale == 'all' or r.get('locale', r.get('language')) == locale]
                    subsuites = ['localized', 'history'] if suite == 'described' else [suite]
                    for subsuite in subsuites:
                        chosen = [r for r in localized if r.get('sourceSuite', suite) == subsuite]
                        for depth in (range(5) if subsuite == 'history' else [None]):
                            subset = [r for r in chosen if depth is None or r['historyDepth'] == depth]
                            if not subset:
                                continue
                            key = '/'.join(str(x) for x in ['laya', suite, variant, part, locale, depth])
                            metric = four_metrics(subset) if suite == 'four' else METRICS(subset)
                            if subsuite == 'history' and part == 'main':
                                metric['alwaysResolvable'] = METRICS([r for r in subset if r['requiredHistory'] == 0])
                            groups[key] = metric
        new = {(r['variant'], r['id']):r for r in rows}
        if suite == 'described':
            baselines = {'vela31': 'decision-vela31-described-noul-results-2026-11-18.json'}
        else:
            baselines = {model: f'decision-vela31-comparison-{model}-{suite}-2026-11-18.json'
                         for model in ['vela3', 'vela31']}
            baselines['d3'] = {
                'four': 'decision-prompt-optimization-holdout-results-2026-11-16.json',
                'binary': 'decision-binary-d3-results-2026-11-17.json',
                'localized': 'decision-localized-binary-d3-summary-2026-11-17.json',
                'history': 'decision-history-binary-d3-summary-2026-11-17.json',
            }[suite]
        for model, name in baselines.items():
            source = DATA / name
            sources[name] = digest(source)
            previous = json.loads(source.read_text())['rows']
            for variant in sorted({r['variant'] for r in rows}):
                matched = [(r, new[r['variant'], r['id']]) for r in previous
                           if r['variant'] == variant and (r['variant'], r['id']) in new
                           and r['expected'] != 'unspecified'
                           and (suite != 'four' or r['group'] == 'holdout')]
                for a,b in matched:
                    assert a['expected'] == b['expected']
                pairs[f'{model}/{suite}/{variant}'] = dict(
                    count=len(matched),
                    layaCorrectOtherWrong=sum(a['prediction'] != a['expected'] and b['prediction'] == b['expected'] for a,b in matched),
                    otherCorrectLayaWrong=sum(a['prediction'] == a['expected'] and b['prediction'] != b['expected'] for a,b in matched),
                    disagreements=[dict(id=a['id'], expected=a['expected'], other=a['prediction'], laya=b['prediction'])
                                   for a,b in matched if a['prediction'] != b['prediction']])
    save(DATA / 'decision-laya-summary-2026-11-18.json', dict(
        groups=groups, paired=pairs, sources=sources,
        note='Previous models are frozen reference runs, not concurrent latency measurements. '
             'choice_native_control names a Vela/D3 control, not a Laya equivalence claim.'), True)


if __name__ == '__main__':
    main()
