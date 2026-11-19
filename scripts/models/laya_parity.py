"""Three published reference rows verify native graph/readout and tokenizer parity."""

import sys
from pathlib import Path
REPOSITORY = next(p for p in Path(__file__).resolve().parents if (p / 'MobileHarness').is_dir())

import asyncio
import json
import sys

import hashlib
HERE = Path(__file__).resolve().parent
ROOT = REPOSITORY / 'Models/LayaMultilingual'

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream, 'sha256').hexdigest()

def save(path, value, first=False):
    with path.open('x' if first else 'w') as stream:json.dump(value, stream, ensure_ascii=False, indent=2)


async def main(output):
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
    save(output, report, True)
    for index, row in enumerate(reference['rows'][:3]):
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
    report['passed'] = all(r['passed'] for r in report['rows']) and len(report['rows']) == 3
    save(output, report)
    print('Parity passed:', report['passed'], flush=True)
    if not report['passed']:
        raise ValueError('Reference parity failed; do not run routing matrix')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    asyncio.run(main(parser.parse_args().output))
