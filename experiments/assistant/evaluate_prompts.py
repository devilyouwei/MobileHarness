"""Compare model responses to explicit prompt variants, without App dependencies."""
import argparse
import asyncio
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from utils.runtime import chat_model,digest,positive,run_cases


async def run(args):
    fixtures=json.loads(args.input.read_text());variants=json.loads(args.variants.read_text())
    cases=[dict(id=f"{variant}/{f['scenario']}",messages=[dict(role='system',content=prompt)]+f['messages'][1:])
           for variant,prompt in variants.items() for f in fixtures]
    model=await chat_model(json.loads(args.config.read_text()),args.timeout)
    async def evaluate(case):
        answer=await model.chat(case['messages'])
        # This runner collects raw output; semantic quality is not fabricated from nonempty text.
        return dict(**answer,passed=bool(answer['text'].strip()),scoring='response-present; semantic review required')
    return await run_cases(cases,evaluate,args.output,timeout=args.timeout,
                          provenance=dict(inputSHA256=digest(args.input),variantsSHA256=digest(args.variants)))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path,default=Path(__file__).parent/'datasets/assistant-prompt-cases.json')
    p.add_argument('--variants',type=Path,required=True,help='JSON mapping variant name to system prompt')
    p.add_argument('--config',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--timeout',type=positive,default=90);args=p.parse_args()
    if args.output.exists():p.error('Output must be new')
    return asyncio.run(run(args))


if __name__=='__main__':raise SystemExit(main())
