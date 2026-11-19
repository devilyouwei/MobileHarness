"""Evaluate frozen Decision requests directly in Python (choice, boolean or chat)."""
import argparse
import asyncio
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from utils.runtime import ROOT, chat_model, digest, positive, run_cases
from decision_models import NativeDecision

ACTIONS = ['interrupt', 'discard', 'enqueue', 'continue_listening']


def strict_label(text, labels):
    return labels.get(text.strip())


def cases_from(document):
    if isinstance(document, dict) and 'models' in document:
        raw = []
        for language, group in document['models']['edge']['conditions'].items():
            for row in group['rows']:
                prompt = row['prompt']
                prefix = '<|im_start|>system\n'
                boundary = '<|im_end|>\n<|im_start|>user\n'
                suffix = '<|im_end|>\n<|im_start|>assistant'
                if not prompt.startswith(prefix) or boundary not in prompt or suffix not in prompt:
                    raise ValueError('Unrecognized frozen prompt')
                system, user = prompt[len(prefix):].split(boundary, 1)
                raw.append(dict(row, system=system, user=user.split(suffix, 1)[0], digits=False, condition=language))
    else:
        raw = document if isinstance(document, list) else document.get('rows', document.get('cases'))
    if not raw:
        raise ValueError('Expected nonempty rows or cases')
    cases = []
    for index, item in enumerate(raw):
        scenario = item.get('scenario', item)
        base = dict(id='/'.join(str(x) for x in [item.get('variant'), item.get('condition'), scenario.get('id', index)] if x is not None), expected=scenario.get('expected'),
                    variant=item.get('variant'), language=scenario.get('language', item.get('condition')),
                    scored=scenario.get('partition') not in ('probe', 'ambiguous'))
        if 'questions' in item:
            for order in ['interrupt_first', 'discard_first']:
                keys = list(item['questions']); keys.sort(key=lambda k: (k != 'interrupt') if order == 'interrupt_first' else (k == 'interrupt'))
                cases.append(dict(base, id=base['id'] + '/' + order, sourceID=base['id'], order=order,
                    text=item['text'], questions={k: dict(type='noul', instructions=item['questions'][k]) for k in keys},
                    expected={k: item.get(k, not item['discard'] if k == 'meaningful' else None) for k in keys}))
        elif 'request' in item or 'native' in item:
            request = item.get('request', item.get('native'))
            actions = request.get('actions', ACTIONS[:len(request['candidates'])])
            if len(actions) != len(request['candidates']):raise ValueError('Candidate/action count mismatch')
            question = item.get('question') or dict(type='choice', instructions=request['instructions'],
                criteria=dict(zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ', request['candidates'])))
            cases.append(dict(base, text=request['text'], question=question, actions=actions))
        elif 'system' in item and 'user' in item:
            labels = dict(zip('123' if item.get('digits', True) else 'ABC', ACTIONS))
            cases.append(dict(base, messages=[dict(role='system', content=item['system']),
                         dict(role='user', content=item['user'])], labels=labels))
        elif 'english' in item and 'chinese' in item:
            for language, key in [('en', 'english'), ('zh-Hans', 'chinese')]:
                transcript = item[key]
                text = json.dumps(dict(running=item['running'], playing=item['playing'], **transcript), ensure_ascii=False)
                request = dict(text=text, instructions='Classify the latest user input in context.',
                    candidates=['Explicit immediate interruption of an active reply', 'Noise or meaningless input',
                                'Meaningful request, question, addition or answer'], actions=ACTIONS[:3])
                cases.extend(cases_from([dict(scenario=dict(id=base['id']+'/'+language, expected=base['expected'], language=language), request=request)]))
        elif 'text' in item and isinstance(item.get('expected'), bool):
            cases.append(dict(base, text=item['text'], question=dict(type='noul', instructions=
                'Does the latest user message explicitly ask to stop, pause, correct or replace the current response immediately? Quoted, negated or deferred requests do not qualify.')))
        elif 'input' in item or 'latest' in item:
            state = {k:v for k,v in item.items() if k not in ('expected','id','group','language')}
            candidates=['Explicit immediate interruption of an active reply','Noise or meaningless input',
                        'Meaningful complete request, question, statement or answer']
            if item.get('speech'):candidates.append('An unfinished utterance that needs more words')
            request=dict(text=json.dumps(state,ensure_ascii=False),instructions='Classify the latest user input in context.',candidates=candidates,actions=ACTIONS[:len(candidates)])
            cases.extend(cases_from([dict(scenario=base,request=request)]))
        else:
            raise ValueError('Unrecognized Decision case schema')
    return cases


async def evaluate_case(case, native=None, chat=None):
    result = {k: v for k, v in case.items() if k in ['variant', 'language', 'expected', 'sourceID', 'order', 'scored']}
    if 'messages' in case:
        if chat is None:raise ValueError('Chat cases require --config')
        answer = await chat.chat(case['messages'])
        prediction = strict_label(answer['text'], case['labels'])
        return dict(result, **answer, prediction=prediction, passed=prediction == case['expected'])
    questions = case.get('questions', {'decision': case.get('question')})
    answers = {}
    for key, question in questions.items():
        if native is not None:
            answer = await native.predict(case['text'], question)
        else:
            criteria = {'false': 'No', 'true': 'Yes'} if question['type'] == 'noul' else question['criteria']
            response = await chat.chat([dict(role='system', content='Return exactly one of these labels, with no explanation: '+', '.join(criteria)),
                dict(role='user', content=json.dumps(dict(state=case['text'],question=question['instructions'],options=criteria),ensure_ascii=False))])
            label = response['text'].strip()
            result.setdefault('responses', []).append(response)
            if label not in criteria:return dict(result, passed=False, prediction=None, issues=['invalidDecisionOutput'])
            answer = dict(noul=float(label == 'true')) if question['type']=='noul' else dict(choice=label)
        if question['type'] == 'noul':
            probability = answer['noul']
            if not isinstance(probability, (int, float)) or not 0 <= probability <= 1:raise ValueError('Invalid boolean score')
            value = probability > .5
            if isinstance(case.get('expected'), str):value = str(value).lower()
            answers[key] = dict(value=value, score=probability)
        else:
            keys = list(question['criteria'])
            prediction = case.get('actions', list(question['criteria']))[keys.index(answer['choice'])]
            answers[key] = dict(value=prediction, probabilities=answer.get('probabilities'))
    prediction = {k: a['value'] for k, a in answers.items()} if 'questions' in case else answers['decision']['value']
    return dict(result, answers=answers, prediction=prediction, passed=prediction == case['expected'])


async def run(args):
    cases = cases_from(json.loads(args.input.read_text()))
    if args.limit:cases = cases[:args.limit]
    native = chat = None
    try:
        if args.model:native = await NativeDecision.load(args.model, args.models_root)
        else:chat = await chat_model(json.loads(args.config.read_text()), args.timeout)
        for case in cases[:min(args.warmup, len(cases))]:
            await asyncio.wait_for(evaluate_case(case, native, chat), args.timeout)
        return await run_cases(cases, lambda c: evaluate_case(c, native, chat), args.output,
            timeout=args.timeout, provenance=dict(inputSHA256=digest(args.input), runnerSHA256=digest(__file__),
                model=args.model, configSHA256=digest(args.config) if args.config else None,
                excludedWarmups=min(args.warmup, len(cases))))
    finally:
        if native:await native.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    model = p.add_mutually_exclusive_group(required=True)
    model.add_argument('--model', choices=['d3-edge', 'vela3-fast', 'vela31-fast', 'laya'])
    model.add_argument('--config', type=Path, help='Chat backend configuration for Apple, Core AI or cloud')
    p.add_argument('--models-root', type=Path, default=ROOT / 'Models')
    p.add_argument('--limit', type=positive); p.add_argument('--timeout', type=positive, default=90)
    p.add_argument('--warmup', type=int, choices=range(0, 11), default=3)
    args = p.parse_args()
    if args.output.exists():p.error('Output must be a new file')
    return asyncio.run(run(args))


if __name__ == '__main__':raise SystemExit(main())
