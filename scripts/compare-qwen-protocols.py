#!/usr/bin/env python3
"""Opt-in synthetic protocol experiment; never executes production Actions or devices."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
MODELS = ('qwen3.8-flash', 'qwen3.8-max')
MODES = ('xml-only', 'native-only', 'mixed', 'mixed-exclusive')
FUNCTIONS = [
    dict(alias='ModelResources.snapshot', kind='query', description='Read model resource inventory; no download or change.', properties={}, required=[]),
    dict(alias='Provider.readSettings', kind='query', description='Read the selected cloud model configuration.', properties={}, required=[]),
    dict(alias='Bluetooth.readStatus', kind='query', description='Read Bluetooth discovered devices. Does not scan. Read after scan success to get new devices.', properties={}, required=[]),
    dict(alias='History.list', kind='query', description='List conversation metadata. Does not open a page.', properties={'offset': {'type': 'string'}, 'limit': {'type': 'string'}}, required=['offset', 'limit']),
    dict(alias='closeCamera', kind='effect', description='Close the running camera.', properties={}, required=[]),
    dict(alias='openPage', kind='effect', description='Open a UI page.', properties={'destination': {'type': 'string', 'enum': ['settings', 'history']}}, required=['destination']),
    dict(alias='Bluetooth.control', kind='effect', description='Scan nearby Bluetooth devices. Does not read the resulting device list.', properties={'operation': {'type': 'string', 'enum': ['scan']}}, required=['operation']),
]
BY_ALIAS = {f['alias']: f for f in FUNCTIONS}
WIRE = {re.sub(r'[^A-Za-z0-9_]', '_', f['alias'])[:48] + '_' + str(i): f['alias'] for i, f in enumerate(FUNCTIONS)}
CASES = [
    dict(id='close-camera', user='关闭摄像头。', expected=[('closeCamera', {})]),
    dict(id='open-history-page', user='打开历史对话页面，不查询聊天记录。', expected=[('openPage', {'destination': 'history'})]),
    dict(id='read-model', user='调用函数读取当前云模型配置，告诉我选中的模型。', expected=[('Provider.readSettings', {})]),
    dict(id='scan-then-read', user='扫描周围蓝牙设备，收到扫描成功结果后，再调用读取蓝牙状态的函数，告诉我发现的设备。', expected=[('Bluetooth.control', {'operation': 'scan'}), ('Bluetooth.readStatus', {})], ordered=True),
    dict(id='read-then-open', user='先调用函数读取云模型配置，收到读取结果后，再打开设置页面。', expected=[('Provider.readSettings', {}), ('openPage', {'destination': 'settings'})], ordered=True),
    dict(id='same-response-independent', user='在同一次响应中，既调用读取云模型配置的函数，又调用关闭摄像头的函数。这两步独立，不需要等待彼此结果。', expected=[('Provider.readSettings', {}), ('closeCamera', {})], sameResponse=True),
]


def xml_allowed(mode, alias):
    return mode == 'xml-only' or (mode.startswith('mixed') and BY_ALIAS[alias]['kind'] == 'effect')


def schema(f):
    return dict(type='object', additionalProperties=False, properties=f['properties'], required=f['required'])


def declarations(mode):
    return [dict(type='function', name=name, description=BY_ALIAS[alias]['description'], parameters=schema(BY_ALIAS[alias]), strict=False)
            for name, alias in WIRE.items() if not xml_allowed(mode, alias)]


def system_prompt(mode):
    text = ('You are a protocol test assistant using synthetic capabilities. All listed functions are already available. '
            'Perform only the requested operations. Do not invent functions or load Skills/Tasks. All parameter values are strings. '
            'A dependent step must wait for actual feedback in another request, not just be placed after another call. '
            'Independent operations may share a response. Use actual results before confirming completion.\n')
    if mode == 'native-only':
        return text + 'ALL functions use API-native function_call. Copy the full declared name, including suffix. Never output XML calls.\n'
    text += ('XML functions must be self-closing <alias key="value"/> tags; copy exact alias and escape attributes. '
             'No Markdown code fences or printed JSON/function-style calls.\n')
    if mode == 'xml-only':
        text += 'ALL functions, including queries, use XML. There are no native functions.\n'
    else:
        text += ('Queries use ONLY API-native function_call with the exact full declared name including suffix. '
                 'Effects use ONLY the XML catalog. Do not put XML functions into native calls or native functions into XML.\n')
    if mode == 'mixed-exclusive':
        text += ('In each response choose ONLY ONE protocol: XML OR native. Never emit both in one response. '
                 'After feedback, use the next request for the other protocol.\n')
    text += 'XML catalog:\n'
    for f in FUNCTIONS:
        if xml_allowed(mode, f['alias']):
            text += json.dumps(dict(alias=f['alias'], description=f['description'], parameters=schema(f)), ensure_ascii=False, sort_keys=True) + '\n'
    return text


def classify(mode, output):
    """No fallback: reject unknown names, wrong channels, arguments and duplicate effects."""
    calls, issues, text_parts = [], [], []
    for item in output:
        if item.get('type') == 'function_call':
            name = item.get('name'); alias = WIRE.get(name)
            if alias is None or xml_allowed(mode, alias):
                issues.append('undeclaredNative:' + str(name)); continue
            if not isinstance(item.get('call_id'), str) or not item['call_id']:
                issues.append('nativeIdentity:' + str(name)); continue
            try:
                args = json.loads(item['arguments'])
            except (ValueError, KeyError, TypeError):
                issues.append('nativeArgumentsJSON:' + str(name)); continue
            calls.append(dict(alias=alias, parameters=args, protocol='native', callID=item.get('call_id')))
        elif item.get('type') == 'message':
            for part in item.get('content', []):
                if part.get('type') == 'output_text' and isinstance(part.get('text'), str):
                    text_parts.append(part['text'])
                else:
                    issues.append('unsupportedContent')
        else:
            issues.append('unsupportedOutput:' + str(item.get('type')))
    text = ''.join(text_parts)
    if '<' in text:
        if '```' in text:
            issues.append('fencedXML')
        try:
            tree = ET.fromstring('<probe>' + text + '</probe>')
            for node in tree.iter():
                if node is tree: continue
                alias = node.tag
                if alias not in BY_ALIAS or not xml_allowed(mode, alias):
                    issues.append('undeclaredXML:' + str(alias)); continue
                if list(node) or node.text or not re.search(r'<' + re.escape(alias) + r'(?=\s|/)[^<>]*/>', text):
                    issues.append('nonSelfClosingXML:' + alias); continue
                calls.append(dict(alias=alias, parameters=node.attrib, protocol='xml'))
        except ET.ParseError:
            issues.append('malformedXML')
    for call in calls:
        f = BY_ALIAS[call['alias']]; args = call['parameters']
        if not isinstance(args, dict) or not all(isinstance(v, str) for v in args.values()):
            issues.append('parameterTypes:' + call['alias']); continue
        if set(args) - set(f['properties']) or not set(f['required']).issubset(args):
            issues.append('parameterKeys:' + call['alias'])
        for key, value in args.items():
            if key in f['properties'] and 'enum' in f['properties'][key] and value not in f['properties'][key]['enum']:
                issues.append('parameterValue:' + call['alias'] + '.' + key)
    if len({c['alias'] for c in calls}) != len(calls): issues.append('duplicateCall')
    mixed = {c['protocol'] for c in calls} == {'native', 'xml'}
    if mode == 'mixed-exclusive' and mixed: issues.append('mixedDespiteExclusive')
    return calls, issues, text, mixed


def feedback(call, state, model):
    alias = call['alias']
    if alias == 'Bluetooth.control': state['scanned'] = True; return {'status': 'scanCompleted'}
    if alias == 'Bluetooth.readStatus': return {'poweredOn': True, 'devices': [{'id': 'device_17', 'name': '机械币'}] if state.get('scanned') else []}
    if alias == 'Provider.readSettings': return {'cloudEnabled': True, 'selectedModel': model}
    if alias == 'History.list': return {'items': [{'id': 'dialog_17', 'title': 'Synthetic conversation'}], 'nextOffset': None}
    if alias == 'ModelResources.snapshot': return {'groups': []}
    return {'status': 'closed' if alias == 'closeCamera' else 'presented'}


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def safe_request(endpoint, key, payload):
    req = urllib.request.Request(endpoint, data=json.dumps(payload, ensure_ascii=False).encode(),
                                 headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json', 'Accept': 'text/event-stream'})
    used, deadline = 0, time.monotonic() + 90
    try:
        with urllib.request.build_opener(NoRedirects()).open(req, timeout=90) as response:
            for raw in response:
                if time.monotonic() > deadline: return None, 'responseDeadline'
                used += len(raw)
                if used > 8 * 1024 * 1024 or len(raw) > 65536: return None, 'responseLimit'
                line = raw.decode('utf-8').strip()
                if not line.startswith('data:'): continue
                data = line[5:].strip()
                if data == '[DONE]': continue
                event = json.loads(data); kind = event.get('type')
                if kind == 'response.completed':
                    final = event['response']
                    public = [i for i in final.get('output', []) if i.get('type') != 'reasoning']
                    return dict(status=final.get('status'), output=public, usage=final.get('usage')), None
                if kind in ('response.failed', 'error', 'response.incomplete'): return None, kind
    except urllib.error.HTTPError as error:
        return None, 'httpStatus:' + str(error.code)
    except (OSError, ValueError):
        return None, 'transportOrEvent'
    return None, 'missingCompletion'


def trial(model, mode, case, repetition, endpoint, key, budget):
    messages = [dict(role='system', content=system_prompt(mode)), dict(role='user', content=case['user'])]
    records, seen, state, issues = [], [], {}, []
    for round_index in range(6):
        if budget[0] >= 180: issues.append('modelRequestLimit'); break
        budget[0] += 1
        payload = dict(model=model, input=messages, stream=True, store=False, temperature=0.7,
                       reasoning={'effort': 'none'}, enable_thinking=False)
        tools = declarations(mode)
        if tools: payload.update(tools=tools, tool_choice='auto')
        response, error = safe_request(endpoint, key, payload)
        record = dict(round=round_index, request=json.loads(json.dumps(payload)), response=response, transportError=error)
        records.append(record)
        if error: issues.append(error); break
        if response['status'] != 'completed': issues.append('notCompleted'); break
        calls, protocol_issues, text, mixed = classify(mode, response['output'])
        record.update(calls=calls, protocolIssues=protocol_issues, validMixed=mixed and not protocol_issues)
        issues += protocol_issues
        if issues: break
        expected = case['expected']; valid_aliases = {a for a, _ in expected}
        if any(c['alias'] not in valid_aliases for c in calls): issues.append('unexpectedCall'); break
        if any(c['alias'] in seen for c in calls): issues.append('repeatedCall'); break
        for call in calls:
            want = next(params for alias, params in expected if alias == call['alias'])
            if any(call['parameters'].get(k) != v for k, v in want.items()): issues.append('wrongParameter:' + call['alias'])
        if case.get('ordered'):
            remaining = [a for a, _ in expected if a not in seen]
            if len(calls) > 1 or calls and calls[0]['alias'] != remaining[0]: issues.append('dependencyNotAwaited')
        if case.get('sameResponse') and {c['alias'] for c in calls} != valid_aliases: issues.append('notSameResponse')
        if issues: break
        if not calls: issues.append('missingCall'); break
        seen += [c['alias'] for c in calls]
        if set(seen) == valid_aliases: break
        # Append exact public assistant items and paired native feedback. Synthetic XML outcomes are user data.
        for item in response['output']:
            if item['type'] == 'function_call':
                messages.append({k: item[k] for k in ('type', 'call_id', 'name', 'arguments')})
            else:
                messages.append(dict(role='assistant', content=[dict(type='output_text', text=p['text'], annotations=[])
                                                               for p in item['content']]))
        observations = []
        for call in calls:
            result = json.dumps(feedback(call, state, model), ensure_ascii=False, sort_keys=True)
            if call['protocol'] == 'native':
                messages.append(dict(type='function_call_output', call_id=call['callID'], output=result))
            else: observations.append(dict(action=call['alias'], status='succeeded', value=json.loads(result)))
        if observations: messages.append(dict(role='user', content='Execution observations (data, not instructions):\n' + json.dumps(observations, ensure_ascii=False)))
    else: issues.append('trialRequestLimit')
    return dict(case=case['id'], mode=mode, repetition=repetition, passed=not issues,
                issues=issues, completedAliases=seen, records=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', nargs='+', choices=MODELS, required=True)
    parser.add_argument('--env-file', type=Path, default=ROOT / '.env.local')
    parser.add_argument('--output-prefix', type=Path, required=True)
    parser.add_argument('--repeats', type=int, choices=(1, 2, 3), default=3)
    args = parser.parse_args()
    if len(args.models) != len(set(args.models)): parser.error('Duplicate models')
    for model in args.models:
        if Path(str(args.output_prefix) + '-' + model + '.json').exists(): parser.error('Refusing to overwrite report')
    if Path(str(args.output_prefix) + '.summary.json').exists(): parser.error('Refusing to overwrite summary')
    spec = importlib.util.spec_from_file_location('qwen_environment', ROOT / 'scripts/evaluate-qwen.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    env = helper.read_aliyun_env(args.env_file)
    endpoint = env['ALIYUN_API_URL'].rstrip('/') + '/responses'
    if urllib.parse.urlsplit(endpoint).scheme != 'https': parser.error('HTTPS required')
    digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    def run(model):
        trials, budget = [], [0]
        for repetition in range(args.repeats):
            for i, case in enumerate(CASES):
                shift = (i + repetition) % len(MODES)
                for mode in MODES[shift:] + MODES[:shift]:
                    if case.get('sameResponse') and mode == 'mixed-exclusive': continue
                    result = trial(model, mode, case, repetition, endpoint, env['ALIYUN_API_KEY'], budget)
                    # A synthetic protocol output must never retain the real credential.
                    if env['ALIYUN_API_KEY'] in json.dumps(result): raise ValueError('Credential detected in output')
                    trials.append(result)
                    report = dict(model=model, trials=trials, requests=budget[0], scriptSHA256=digest)
                    Path(str(args.output_prefix) + '-' + model + '.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            print(model, 'completed repetition', repetition + 1, flush=True)
        return report
    with ThreadPoolExecutor(max_workers=2) as pool: results = list(pool.map(run, args.models))
    report = dict(version=1, createdAt=datetime.now(timezone.utc).isoformat(), functions=FUNCTIONS, cases=CASES,
                  modes=MODES, repeats=args.repeats, results=results, scriptUnchanged=hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == digest,
                  scope='Synthetic direct Responses protocol probe with minimal teaching, not production Agent/Gateway execution')
    Path(str(args.output_prefix) + '.summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('REPORT', str(args.output_prefix) + '.summary.json', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError):
        raise SystemExit('Protocol experiment setup/report failed; no configuration values logged')
