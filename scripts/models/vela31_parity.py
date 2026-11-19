"""Verify native loading against published model reference answers."""

import sys
from pathlib import Path
REPOSITORY = next(p for p in Path(__file__).resolve().parents if (p / 'MobileHarness').is_dir())

import asyncio
import json
from pathlib import Path

import contextlib
import hashlib

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream, 'sha256').hexdigest()

class LocalView:
    def __init__(self, root):self.root=root
    def view(self):return contextlib.nullcontext(self.root)

from hugging_mac_sdk.models.vela.coreai import CoreAIVelaEngine
from hugging_mac_sdk.models.vela.config import VelaInstanceConfig
from hugging_mac_sdk.models.vela.definition import COREAI_LAYOUT
from hugging_mac_sdk.models.vela.utils.validation import compare


async def main(source, output):
    reference = json.loads(source.read_text())
    root = REPOSITORY / 'Models/Vela31Fast'
    engine = CoreAIVelaEngine(
        VelaInstanceConfig(variant='3_1-fast', runtime='coreai', device='cpu', artifact_path=root),
        LocalView(root), COREAI_LAYOUT, model_name='vllm-sr/vela3.1-fast')
    report = dict(referenceSHA256=digest(source), sourceDigest=reference['source_digest'], rows=[])
    try:
        await engine.load(root)
        for case, expected in zip(reference['cases'], reference['responses']):
            if case['id'] not in ['decision-multilingual', 'decision-structured-multiple', 'decision-single-option']:
                continue
            actual = await engine.infer(state=case['state'], questions=case['questions'])
            error = compare(actual, expected['response'])
            report['rows'].append(dict(case=case, expected=expected['response'], actual=actual, maxAbsoluteError=error))
        report['passed'] = len(report['rows']) == 3
        with output.open('x') as out:
            json.dump(report, out, ensure_ascii=False, indent=2)
        print('Original reference parity:', report['passed'], flush=True)
    finally:
        await engine.close()


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    asyncio.run(main(args.reference, args.output))
