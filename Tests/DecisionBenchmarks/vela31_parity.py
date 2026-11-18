"""Verify the experiment loader against frozen original-model reference answers."""
import asyncio
import json
from pathlib import Path

from vela31_comparison import HERE, DATA, LocalView, digest
from hugging_mac_sdk.models.vela.coreai import CoreAIVelaEngine
from hugging_mac_sdk.models.vela.config import VelaInstanceConfig
from hugging_mac_sdk.models.vela.definition import COREAI_LAYOUT
from hugging_mac_sdk.models.vela.utils.validation import compare


async def main():
    source = Path('/Users/devil/Pro/hugging-mac/tmp/evaluations/vela/3_1-fast/20261117T064718Z-fa9799cc/reference.json')
    reference = json.loads(source.read_text())
    root = HERE / '.local/models/Vela31Fast'
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
        with (DATA / 'decision-vela31-native-parity-2026-11-18.json').open('x') as out:
            json.dump(report, out, ensure_ascii=False, indent=2)
        print('Original reference parity:', report['passed'], flush=True)
    finally:
        await engine.close()


if __name__ == '__main__':
    asyncio.run(main())
