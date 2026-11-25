"""Evaluate ending Assistant quiet mode from the latest sentence and optional wake agreement in Python.

With a prompts file whose "answer" is "boolean" (the wake question), chat backends answer true/false instead and true
counts as exit.

Chat backends (Apple system model, cloud) get the Assistant's judge prompt: instructions as the system message, the
sentence as the user message, one word answer exit/stay. Native Decision models (d3, vela, laya) cannot answer words,
so they get a boolean question over the same evidence; probability > 0.5 means exit.
Version 1 prompt fixtures preserve the original request and parsing behavior.
"""
import argparse
import asyncio
from collections import Counter
from importlib.metadata import PackageNotFoundError, version
import json
from pathlib import Path
import platform
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from utils.runtime import ROOT, chat_model, digest, positive, run_cases, write_report

HERE = Path(__file__).resolve().parent
LABELS = ('exit', 'stay')


def parse_answer(text):
    """Parse historical version 1 fixtures, which permitted an explanation."""
    text = text.strip()
    word = ''
    for character in text:
        if not character.isalpha():
            break
        word += character
    word = word.lower()
    if word not in LABELS:
        return None, None
    reason = text[len(word):].strip(' \t\r\n.,;:!?-—，。；：！？') or None
    return word, reason


def parse_boolean(text):
    """First alphabetic word must be true or false (the wake-question form); anything after it is the reason."""
    word = ''
    for character in text.strip():
        if not character.isalpha():
            break
        word += character
    word = word.lower()
    if word not in ('true', 'false'):
        return None, None
    reason = text.strip()[len(word):].strip(' \t\r\n.,;:!?-—，。；：！？') or None
    return ('exit' if word == 'true' else 'stay'), reason


def load_cases(document, limit=None):
    cases = document['cases']
    if len({c['id'] for c in cases}) != len(cases):
        raise ValueError('Duplicate case ids')
    for case in cases:
        if case['expected'] not in LABELS or case['language'] not in ('en', 'zh-Hans') or not case['sentence'].strip():
            raise ValueError('Invalid case: ' + case['id'])
        if 'wakeCondition' in case:
            condition = case['wakeCondition']
            if not isinstance(condition, str) or not condition.strip() or condition.startswith('literal:'):
                raise ValueError('Expected a semantic wake condition: ' + case['id'])
    return cases[:limit] if limit else cases


def request_for(case, prompts, native):
    language = case['language']
    sentence = case['sentence'].strip()
    if prompts.get('version') == 2:
        sentence = sentence[:512]
        template = 'instructions'
        state = sentence
        if 'wakeCondition' in case:
            template = 'conditioned'
            state = json.dumps(dict(latestUtterance=sentence, wakeCondition=case['wakeCondition']),
                               ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        if native:
            return dict(state=state, question=dict(type='noul', instructions=prompts['decision'][language][template]))
        return dict(messages=[dict(role='system', content=prompts['chat'][language][template]),
                              dict(role='user', content=state)])
    if 'wakeCondition' in case:
        raise ValueError('Wake conditions require version 2 prompts')
    if native:
        state = json.dumps(dict(latest_user_sentence=case['sentence']), ensure_ascii=False)
        return dict(state=state, question=dict(type='noul', instructions=prompts['decision'][language]))
    if 'template' in prompts:
        question = prompts['template'][language].replace('{sentence}', sentence)
        return dict(messages=[dict(role='user', content=question)])
    return dict(messages=[dict(role='system', content=prompts['chat'][language]),
                          dict(role='user', content=sentence)])


async def evaluate_case(case, prompts, native=None, chat=None):
    result = dict(language=case['language'], group=case['group'], expected=case['expected'],
                  scored=case.get('partition') != 'ambiguous')
    request = request_for(case, prompts, native is not None)
    if native is not None:
        answer = await native.predict(request['state'], request['question'])
        if not 0 <= answer['noul'] <= 1:
            raise ValueError('Invalid noul score')
        prediction = 'exit' if answer['noul'] > .5 else 'stay'
        return dict(result, prediction=prediction, score=answer['noul'], inputTokens=answer.get('inputTokens'),
                    passed=prediction == case['expected'])
    answer = await chat.chat(request['messages'])
    if prompts.get('version') == 2:
        word = answer['text'].strip().lower()
        prediction, reason = (word if word in LABELS else None), None
    else:
        parse = parse_boolean if prompts.get('answer') == 'boolean' else parse_answer
        prediction, reason = parse(answer['text'])
    result.update(prediction=prediction, reason=reason, response=answer['text'], passed=prediction == case['expected'])
    for key in ('usage', 'finishReason', 'inputTokens', 'outputTokens'):
        if key in answer:
            result[key] = answer[key]
    if prediction is None:
        result['issues'] = ['invalidAnswer']
    return result


def metrics(rows):
    """Confusion over scored rows. A false wake is a stay case answered exit: the assistant would talk over the user."""
    scored = [r for r in rows if r.get('scored') and 'error' not in r]
    count = Counter((r['expected'], r.get('prediction')) for r in scored)
    stay = sum(v for (e, _), v in count.items() if e == 'stay')
    exit_ = sum(v for (e, _), v in count.items() if e == 'exit')
    groups = {}
    for row in scored:
        group = groups.setdefault(row['group'], dict(count=0, passed=0))
        group['count'] += 1
        group['passed'] += row['passed']
    return dict(scoredCases=len(scored), stayCases=stay, exitCases=exit_,
                falseWake=count[('stay', 'exit')], missedExit=count[('exit', 'stay')],
                invalid=sum(1 for r in scored if r.get('prediction') is None),
                falseWakeRate=count[('stay', 'exit')] / stay if stay else None,
                missedExitRate=count[('exit', 'stay')] / exit_ if exit_ else None,
                accuracy=sum(r['passed'] for r in scored) / len(scored) if scored else None,
                byGroup=groups, errors=sum('error' in r for r in rows))


def metrics_by_language(rows):
    return {language: metrics([r for r in rows if r.get('language') == language]) for language in ('zh-Hans', 'en')}

def dependency_versions():
    versions = {}
    for package in ('coreai-core', 'transformers', 'numpy', 'hugging-mac-sdk', 'apple-fm-sdk'):
        try:
            versions[package] = version(package)
        except PackageNotFoundError:
            continue
    return versions


async def run(args):
    document = json.loads(args.input.read_text())
    prompts = json.loads(args.prompts.read_text())
    cases = load_cases(document, args.limit)
    requests = {case['id']: request_for(case, prompts, args.model is not None) for case in cases}
    native = chat = None
    status = 1
    try:
        if args.model:
            from decision_models import NativeDecision
            native = await NativeDecision.load(args.model, args.models_root)
        else:
            chat = await chat_model(json.loads(args.config.read_text()), args.timeout)
        warmups = cases[:min(args.warmup, len(cases))]
        for case in warmups:
            await asyncio.wait_for(evaluate_case(case, prompts, native, chat), args.timeout)
        status = await run_cases(cases, lambda c: evaluate_case(c, prompts, native, chat), args.output,
            timeout=args.timeout, provenance=dict(inputSHA256=digest(args.input), promptsSHA256=digest(args.prompts),
                runnerSHA256=digest(__file__), model=args.model or 'chat',
                configSHA256=digest(args.config) if args.config else None, excludedWarmups=len(warmups),
                timeoutSeconds=args.timeout, requestedCases=len(cases),
                environment=dict(platform=platform.platform(), python=platform.python_version(),
                                 packages=dependency_versions())))
        report = json.loads(args.output.read_text())
        if prompts.get('version') == 2:
            cases_by_id = {case['id']: case for case in cases}
            for row in report['rows']:
                case = cases_by_id[row['id']]
                row.update(language=case['language'], group=case['group'], expected=case['expected'],
                           scored=case.get('partition') != 'ambiguous', request=requests[row['id']])
        report['metrics'] = metrics(report['rows'])
        report['metricsByLanguage'] = metrics_by_language(report['rows'])
        write_report(args.output, report)
    finally:
        if native:
            await native.close()
    return status


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', type=Path, default=HERE / 'datasets' / 'quiet-exit-cases-2026-11-23.json')
    p.add_argument('--prompts', type=Path, default=HERE / 'quiet-exit-prompts.json')
    p.add_argument('--output', type=Path, required=True)
    model = p.add_mutually_exclusive_group(required=True)
    model.add_argument('--model', choices=['d3-edge', 'vela3-fast', 'vela31-fast', 'laya'])
    model.add_argument('--config', type=Path, help='Chat backend configuration for Apple or cloud')
    p.add_argument('--models-root', type=Path, default=ROOT / 'Models')
    p.add_argument('--limit', type=positive)
    p.add_argument('--timeout', type=positive, default=60)
    p.add_argument('--warmup', type=int, choices=range(0, 11), default=2)
    args = p.parse_args()
    if args.output.exists():
        p.error('Output must be a new file')
    return asyncio.run(run(args))


if __name__ == '__main__':
    raise SystemExit(main())
