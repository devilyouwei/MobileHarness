#!/usr/bin/env python3
"""Opt-in, bounded Qwen / GPT-4.1 prompt regression with Python model requests and synthetic action feedback."""

import argparse
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]


def read_provider_env(path, allowed):
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"(?:export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*)", line)
        if not match or match[1] not in allowed:
            continue
        value = match[2].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[match[1]] = value
    return values


def read_aliyun_env(path):
    values = read_provider_env(path, {"ALIYUN_API_URL", "ALIYUN_API_KEY"})
    if not all(values.get(key) for key in ("ALIYUN_API_URL", "ALIYUN_API_KEY")):
        raise ValueError("ENV must define ALIYUN_API_URL and ALIYUN_API_KEY")
    return values



def selected_ids(cases, selection):
    known = {case["id"] for case in cases}
    selected = known if selection is None else set(selection.split(","))
    if not selected or not selected.issubset(known):
        raise ValueError("Unknown or empty workflow selection")
    return selected


# Shared mechanisms stay at the experiment root; task scoring stays beside its inputs.
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.runtime import chat_model, digest, positive, run_cases
import asyncio
from workflow_scoring import parse_actions, score_turn, apply_actions


def agent_state_block(state, configuration):
    """The independent system block the App places before the user message; empty when nothing is set."""
    variables = state.get('variables', {})
    if not variables:return ''
    lines = []
    for name, value in variables.items():
        lines.append(f"{name} (written {configuration['time']}): {json.dumps(value, ensure_ascii=False)}")
    return configuration['stateBlock'].replace('{{variables}}', '\n'.join(lines))


async def evaluate_case(case, model, configuration, request_limit):
    state = {k: v for k, v in case.items() if k not in ('turns', 'id', 'category')}
    state['loaded'] = list(case.get('skills', []))
    state['variables'] = dict(case.get('variables', {}))
    if case.get('taskGoal'):state['variables']['task'] = case['taskGoal']
    state['task'] = 'task' in state['variables']
    messages = [dict(role='system', content=configuration['system'] + '\nAvailable action aliases:\n' +
                     json.dumps(configuration['actions']) + '\nAction attribute names:\n' + json.dumps(configuration.get('parameters', {})) + '\nInitial synthetic state:\n' + json.dumps({k:v for k,v in state.items() if k not in ('failure', 'variables')}))]
    turns = []; requests = 0
    for expected in case['turns']:
        block = agent_state_block(state, configuration)
        if block:messages.append(dict(role='system', content=block))
        messages.append(dict(role='user', content=expected['user']))
        state['rejections'] = []
        calls = []; trace = []; parse_issues = []
        for round_index in range(request_limit):
            if requests >= request_limit:raise ValueError('Case request limit exceeded')
            answer = await model.chat(messages); requests += 1
            text = answer['text']; trace.append(answer)
            messages.append(dict(role='assistant', content=text))
            try:batch = parse_actions(text, round_index, set(configuration['actions']))
            except Exception as error:
                parse_issues.append('invalidActionOutput:' + type(error).__name__); break
            calls.extend(batch)
            if not any(c['alias'] != 'speak' for c in batch):break
            feedback = [f for f in apply_actions(batch, state) if not f.get('void')]
            if not feedback:break
            messages.append(dict(role='user', content='Synthetic action feedback: ' + json.dumps(feedback, ensure_ascii=False)))
        else:raise ValueError('Case request limit exceeded')
        issues = parse_issues + score_turn(expected, calls, state)
        turns.append(dict(user=expected['user'], calls=calls, responses=trace, issues=issues))
    return dict(turns=turns, passed=all(not t['issues'] for t in turns), requests=requests)


async def run(args):
    document = json.loads(args.input.read_text()); cases = document['cases']
    selected = selected_ids(cases, args.cases)
    cases = [c for c in cases if c['id'] in selected]
    configuration = json.loads(args.prompt.read_text())
    model = await chat_model(json.loads(args.config.read_text()), args.timeout)
    return await run_cases(cases, lambda c: evaluate_case(c, model, configuration, args.request_limit),
        args.output, timeout=args.timeout, provenance=dict(inputSHA256=digest(args.input),
            promptSHA256=digest(args.prompt), configSHA256=digest(args.config), runnerSHA256=digest(__file__)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=Path(__file__).parent / 'datasets/qwen-workflows.json')
    parser.add_argument('--prompt', type=Path, default=Path(__file__).parent / 'assistant-evaluation.json')
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cases'); parser.add_argument('--request-limit', type=positive, default=16)
    parser.add_argument('--timeout', type=positive, default=180)
    args = parser.parse_args()
    if args.output.exists():parser.error('Output must be new')
    return asyncio.run(run(args))


if __name__ == '__main__':raise SystemExit(main())
