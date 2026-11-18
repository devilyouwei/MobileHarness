"""Published 201-row graph/readout and host-token parity, before routing evaluation."""
import asyncio
import json
import sys

from vela31_comparison import HERE, DATA, digest, save
from laya_comparison import ROOT


async def main():
    spec = json.loads((HERE / 'laya-model.json').read_text())
    sys.path.insert(0, str(ROOT / spec['hostPackage']['filename']))
    from laya_artifact_adapter import LayaArtifact
    from laya.common import build_sequence
    import numpy as np
    engine = await LayaArtifact.load(ROOT)
    reference_path = ROOT / 'macos/wfp16-s512/reference.json'
    fixtures_path = ROOT / 'fixtures-laya-multilingual.json'
    reference = json.loads(reference_path.read_text())
    fixtures = {r['id']:r['state'] for r in json.loads(fixtures_path.read_text())['fixtures']}
    report = dict(referenceSHA256=digest(reference_path), fixturesSHA256=digest(fixtures_path),
                  adapterSHA256=digest(HERE / 'laya_artifact_adapter.py'), rows=[], complete=False)
    output = DATA / 'decision-laya-parity-2026-11-18.json'
    save(output, report, True)
    for index, row in enumerate(reference['rows']):
        ids, markers = build_sequence(engine.tok, fixtures[row['fixture_id']],
                                      engine._internal(row['question']), engine.max_len, engine.marker_capacity)
        tokens_match = ids == row['sequence_ids'] and markers == row['marker_positions']
        logits, act = await engine.forward(ids, markers, row['qtype'])
        probabilities = engine.host.probabilities(logits, row['qtype'], {'temperature':[1,1,1]})
        delta = float(np.max(np.abs(probabilities - np.asarray(row['probabilities']))))
        act_delta = abs(float(engine.host.softmax(act).reshape(-1)[0]) - row['act_probability'])
        selection = int(np.argmax(probabilities)) == int(np.argmax(row['probabilities']))
        report['rows'].append(dict(id=row['row_id'], tokensMatch=tokens_match,
                                  maxProbabilityDelta=delta, actProbabilityDelta=act_delta,
                                  selectionMatch=selection, logits=logits.tolist(),
                                  passed=bool(tokens_match and selection and delta<=1e-3 and act_delta<=1e-3)))
        if index % 20 == 0:
            save(output, report)
            print(f'parity {index+1}/{len(reference["rows"])}', flush=True)
    report['complete'] = True
    report['passed'] = all(r['passed'] for r in report['rows']) and len(report['rows']) == 201
    save(output, report)
    print('Parity passed:', report['passed'], flush=True)
    if not report['passed']:
        raise ValueError('Reference parity failed; do not run routing matrix')


if __name__ == '__main__':
    asyncio.run(main())
