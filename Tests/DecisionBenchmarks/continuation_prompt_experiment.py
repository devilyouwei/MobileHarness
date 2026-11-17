"""Prepare and score experimental D3 Edge prompts; never edits production prompts."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEASURE = ROOT / 'docs/measurements'
BASE = MEASURE / 'decision-continue-listening-d3-edge-2026-11-16.json'
ACTIONS = ['interrupt', 'discard', 'enqueue', 'continue_listening']
VARIANTS = ['baseline', 'rules_in_question', 'semantic_options', 'semantic_examples', 'continuation_first', 'english_policy', 'official_short']
REFINEMENTS = ['utterance_status', 'explicit_gap', 'minimal_state', 'unfinished_first']
PROBES = {'capacity-probe', 'adoption-probe', 'typed-probe'}


def write(path, value):
    with path.open('x') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n')


def quote(value):
    return json.dumps(value, ensure_ascii=False).replace('<', '\\u003c').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')


def request(c, variant, original=None):
    zh = c['language'] == 'zh-Hans'
    if original is not None and variant in ['baseline', 'rules_in_question']:
        native = original['native']
        text, instruction = native['text'], native['instructions']
        if variant == 'rules_in_question':
            definitions, text = text.split('\n\n', 1)
            instruction = definitions + '\n\n' + instruction
        return dict(text=text, instructions=instruction, candidates=native['candidates'], actions=ACTIONS if c['speech'] else ACTIONS[:3])
    joined = '\n'.join(c['held'] + [c['latest']])
    if variant == 'baseline':
        name = 'InputDecision.zh-Hans.json' if zh else 'InputDecision.json'
        t = json.loads((ROOT / 'MobileHarness/Resources/Agents/Assistant' / name).read_text())['templates']
        def render(key, **values):
            value = t[key]
            for k, v in values.items(): value = value.replace('{{'+k+'}}', v)
            return value
        definitions = t['definitions'] + ('\n' + t['continueDefinition'] if c['speech'] else '')
        state = render('state', running=t['yes'] if c['running'] else t['no'],
                       playing=t['unknown'] if c['playing'] is None else t['yes'] if c['playing'] else t['no'],
                       question=quote(c.get('question')[-80:]) if c.get('question') is not None else t['empty'])
        history = render('history', user=quote(c['user'][-80:]), assistant=quote(c['assistant'][-80:])) if c['user'] or c['assistant'] else t['empty']
        context = render('context', history=history, buffer='\n'.join(quote(x[-80:]) for x in c['buffer'][-3:]) or t['empty'])
        return dict(text='\n\n'.join([definitions, state, context]), instructions=render('latestSpeech' if c['speech'] else 'latest', input=quote(joined)),
                    candidates=['1','2','3','4'] if c['speech'] else ['1','2','3'], actions=ACTIONS if c['speech'] else ACTIONS[:3])
    if variant in REFINEMENTS:
        facts=dict(utterance=joined, assistant_busy=c['running'] or c['playing'] is True,
                   question_to_user=c.get('question'), preceding_assistant=c['assistant'][-80:] or None,
                   preceding_user=c['user'][-80:] or None, queued_inputs=c['buffer'][-3:])
        if variant == 'minimal_state':
            facts={k:v for k,v in facts.items() if k in ['utterance','assistant_busy','question_to_user']}
        instruction = ('Which description best matches the user utterance? It may contain several fragments of the SAME sentence joined by newlines. '
                       'Use a question_to_user to interpret short answers. A stop request requires an assistant that is busy. '
                       'Meaningful unfinished words are speech, not noise.')
        if variant in ['explicit_gap','minimal_state']:
            instruction += (' Decide whether the speaker has supplied the essential object, value or second clause. '
                            'An unfinished sentence is waiting for more words, not waiting for the assistant to do a task. '
                            'Examples: "Make the screen" is unfinished; "Make the screen darker" is complete. '
                            '"Yes", "three", and "the red one" can be complete answers.')
        options = ['stop_request: The user explicitly commands the currently busy assistant to stop now, correct its ongoing work, or immediately switch tasks.',
                   'non_speech: The input is only an ASR noise/silence marker or a standalone hesitation sound with no question to answer.',
                   'complete_utterance: The user has finished expressing a request, question, fact, or answer. The meaning is complete in context, even with very few words.',
                   'unfinished_utterance: The user has started meaningful speech but has not finished the sentence or thought. A required object, value or following clause is still absent.']
        actions=ACTIONS.copy()
        if not c['speech']: options,actions=options[:3],actions[:3]
        if variant == 'unfinished_first' and c['speech']:
            order=[3,0,1,2];options,actions=[options[i] for i in order],[actions[i] for i in order]
        return dict(text=json.dumps(facts,ensure_ascii=False,separators=(',',':')),instructions=instruction,candidates=options,actions=actions)
    english = not zh or variant == 'english_policy'
    # Identical factual fields across semantic variants; numbers and IDs are not model features.
    text = json.dumps(dict(reply_active=c['running'] or c['playing'] is True,
                           running=c['running'], speaking=c['playing'],
                           pending_question=c.get('question')[-80:] if c.get('question') else None,
                           previous_user=c['user'][-80:] or None, previous_reply=c['assistant'][-80:] or None,
                           queued_user_inputs=[x[-80:] for x in c['buffer'][-3:]],
                           latest_speech=joined, source='speech' if c['speech'] else 'typed'), ensure_ascii=False, separators=(',', ':'))
    if english:
        instruction = ('Choose the best next action for latest_speech, interpreting its joined fragments as ONE utterance. '
                       'Use the pending question to resolve short answers. A clear request to stop NOW takes priority while reply_active is true. '
                       'Otherwise, if a required object, parameter, or clause is still missing, wait for more speech. '
                       'A complete request or answer is ready even if very short. Quoted, negated, or deferred stop requests are not interruptions. '
                       'Discard only clear noise or an acknowledgement needing no reply; uncertainty alone is not noise.')
        options = ['Interrupt the active reply now: an explicit immediate stop, correction of current work, or immediate task switch.',
                   'Discard: clear noise, meaningless audio, or an acknowledgement that needs no response.',
                   'Queue for processing: a complete request, question, addition, or contextual answer.',
                   'Keep listening: meaningful speech is clearly unfinished; a required object, value, or clause is still missing.']
        examples = (' Examples: "Set the volume to" → keep listening; "Set the volume to half" → queue. '
                    'After "Which color?", "Green" → queue. "Stop!" during speech → interrupt. '
                    'Judge the combined utterance, not only its last fragment.')
    else:
        instruction = ('为latest_speech选择下一步，把其中用换行接续的片段作为一句完整话来理解。用待答问题判断短回答。'
                       'reply_active为真且用户明确要求现在停止时，优先打断。否则，若必要的对象、参数或分句还没说出，继续聆听。'
                       '已完整表达的请求或回答即使很短也应排队。引用、否定或延后的停止要求不算打断。'
                       '仅明确噪声或无需回应的附和可舍弃，不能因内容不确定就当作噪声。')
        options = ['打断当前回复：明确要求立即停止、纠正正在处理的内容或现在切换任务。',
                   '舍弃：明确的噪声、无意义声音或无需回应的附和。',
                   '排队处理：完整的请求、问题、补充或结合上下文成立的回答。',
                   '继续聆听：有意义但明显未说完，必要对象、参数或后半句仍缺失。']
        examples = (' 例：“把音量调到”→继续聆听；“把音量调到一半”→排队。'
                    '问“哪种颜色？”答“绿色”→排队。播报时说“停！”→打断。应判断接续后的整句话，不能只看最后片段。')
    if variant in ['semantic_examples', 'continuation_first', 'english_policy']:
        instruction += examples
    if variant == 'official_short':
        instruction = ('What should the assistant do with the latest user utterance? Interpret all joined fragments together, using the pending question for short answers.' if english else
                       '助手应如何处理最新用户话语？结合待答问题理解短回答，将接续片段作为整句话判断。')
        options = (['Stop the active reply now because the user explicitly requests immediate stopping, correction, or a task switch; not quoted, negated, or deferred.',
                    'Ignore clear noise or an acknowledgement requiring no response; not a meaningful fragment or answer.',
                    'Process a complete request, question, addition, or contextual short answer; no immediate interruption is needed.',
                    'Wait for the user to finish: meaningful speech lacks a required object, value, or clause; not a complete short answer or an explicit stop command.'] if english else
                   ['当前回复进行中，用户明确要求立即停止、纠正或切换任务；排除引用、否定和延后要求。',
                    '忽略明确噪声或无需回应的附和；不包括有意义的片段或回答。',
                    '处理完整的请求、问题、补充或结合上下文成立的短回答，不必立即打断。',
                    '等用户说完：有意义的话缺少必要对象、参数或后半句；排除完整短回答和明确停止指令。'])
    actions = ACTIONS.copy()
    if not c['speech']:
        options, actions = options[:3], actions[:3]
        instruction += ' Typed input must be handled now; waiting for more speech is unavailable.' if english else ' 键盘输入直接处理，不提供继续聆听。'
    if variant == 'continuation_first' and c['speech']:
        order = [3, 0, 1, 2]
        options, actions = [options[i] for i in order], [actions[i] for i in order]
    options = [action + ': ' + description for action, description in zip(actions, options)]
    return dict(text=text, instructions=instruction, candidates=options, actions=actions)


def holdout():
    pairs = [
        ('alarm','Wake me on Monday at','周一叫醒我，时间定在','six thirty.','六点半。'),
        ('brightness','Change the brightness to','把亮度调成','twenty percent.','百分之二十。'),
        ('attachment','Attach the','附上那份','budget spreadsheet.','预算表。'),
        ('unless','Unless the shop is closed,','除非商店关门了，否则','remind me to buy bread.','提醒我买面包。'),
        ('route','Show the route from the museum to','显示从博物馆到','the library.','图书馆的路线。'),
        ('rewrite','Rewrite the last sentence as','把最后一句改为','See you next week.','下周见。'),
        ('list','Pack socks, shoes, and','打包袜子、鞋子，还有','a jacket.','一件夹克。'),
        ('purpose','I need a note that says','我需要一张便条，上面写','Please close the door.','请关门。'),
    ]
    cases=[]
    def add(id,en,zh,expected,**kw):
        for lang,latest in [('en',en),('zh-Hans',zh)]:
            c=dict(id='holdout-'+id+'-'+lang,group='holdout',language=lang,expected=expected,expectedAdopted=expected,
                   running=False,playing=False,latest=latest,held=[],buffer=[],speech=True,canHold=True,user='',assistant='',question=None)
            for k,v in kw.items():c[k]=v[0 if lang=='en' else 1] if isinstance(v,tuple) else v
            cases.append(c)
    for id,en,zh,ce,cz in pairs:
        add(id+'-unfinished',en,zh,'continue_listening')
        add(id+'-complete',ce,cz,'enqueue',held=([en],[zh]))
    add('short-answer','The smaller one.','小的那个。','enqueue',question=('Which size?','哪种尺寸？'))
    add('short-command','Take a selfie.','拍张自拍。','enqueue')
    add('stop','Be quiet now.','现在别出声了。','interrupt',running=True,playing=True)
    add('switch','Stop this and read my calendar instead.','先停下，改读我的日历。','interrupt',running=True,playing=True)
    add('negated','Keep going, do not stop.','接着说，不要停。','enqueue',running=True,playing=True)
    add('quoted','Write the words stop now.','写下“现在停止”四个字。','enqueue',running=True,playing=True)
    add('noise','[inaudible]','[听不清]','discard')
    add('filler','er','呃','discard')
    return cases


def prepare():
    original=json.loads(BASE.read_text())
    cases=[r['scenario'] for r in original['rows']]
    frozen=holdout()
    holdout_path=MEASURE/'decision-prompt-optimization-holdout-2026-11-16.json'
    holdout_data=dict(cases=frozen,notes='Frozen before development results; evaluate only baseline and selected variant.')
    if holdout_path.exists():
        assert json.loads(holdout_path.read_text()) == holdout_data
    else:
        write(holdout_path,holdout_data)
    rows=[]
    for variant in VARIANTS:
        for c,old in zip(cases,original['rows']):
            rows.append(dict(variant=variant,scenario=c,request=request(c,variant,old)))
    write(MEASURE/'decision-prompt-optimization-input-2026-11-16.json',dict(sourceHashes=original['sourceHashes'],rows=rows))


def refine():
    original=json.loads(BASE.read_text())
    rows=[dict(variant=v,scenario=r['scenario'],request=request(r['scenario'],v,r)) for v in REFINEMENTS for r in original['rows']]
    write(MEASURE/'decision-prompt-optimization-refined-input-2026-11-16.json',dict(sourceHashes=original['sourceHashes'],rows=rows))


def metrics(rows):
    matrix={a:Counter() for a in ACTIONS}
    for r in rows:matrix[r['expected']][r.get('prediction') or 'invalid']+=1
    f1=[]
    for a in ACTIONS:
        tp=matrix[a][a];n=sum(matrix[a].values());p=sum(m[a] for m in matrix.values())
        f1.append(2*tp/(n+p) if n+p else 0)
    h='continue_listening';tp=matrix[h][h];n=sum(matrix[h].values());p=sum(m[h] for m in matrix.values())
    times=sorted(r['milliseconds'] for r in rows if not r.get('error'))
    return dict(count=len(rows),correct=sum(r.get('prediction')==r['expected'] for r in rows),macroF1=sum(f1)/4,
                continueRecall=tp/n if n else 0,continuePrecision=tp/p if p else 0,continueTP=tp,expectedContinue=n,
                falseContinue=p-tp,falseInterrupt=sum(m['interrupt'] for a,m in matrix.items() if a!='interrupt'),
                falseDiscard=sum(m['discard'] for a,m in matrix.items() if a!='discard'),
                invalid=sum(r.get('prediction') is None for r in rows),
                tokensMin=min(r['inputTokens'] for r in rows),tokensMax=max(r['inputTokens'] for r in rows),
                p50MS=times[math.ceil(len(times)*.5)-1] if times else None,
                p95MS=times[math.ceil(len(times)*.95)-1] if times else None,
                over250MS=sum(t>250 for t in times),matrix=matrix)


def summarize(path,output):
    d=json.loads(path.read_text());groups={}
    assert d['sourcesUnchanged'], 'Experiment is incomplete or production sources changed'
    recorded_input=Path(d['inputPath'])
    assert hashlib.sha256(recorded_input.read_bytes()).hexdigest()==d['inputSHA256']
    assert len(d['rows'])==len(json.loads(recorded_input.read_text())['rows'])
    for v in dict.fromkeys(r['variant'] for r in d['rows']):
        selected=[r for r in d['rows'] if r['variant']==v and r['group'] not in PROBES]
        groups[v]={'all':metrics(selected)}
        for lang in ['en','zh-Hans']:groups[v][lang]=metrics([r for r in selected if r['language']==lang])
    write(output,dict(report=path.name,reportSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),groups=groups))
    for v,g in groups.items():print(v,json.dumps(g['all'],ensure_ascii=False))


def prepare_holdout(variant):
    original=json.loads(BASE.read_text());cases=json.loads((MEASURE/'decision-prompt-optimization-holdout-2026-11-16.json').read_text())['cases']
    rows=[dict(variant=v,scenario=c,request=request(c,v)) for v in ['baseline',variant] for c in cases]
    write(MEASURE/'decision-prompt-optimization-holdout-input-2026-11-16.json',dict(sourceHashes=original['sourceHashes'],rows=rows))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('command',choices=['prepare','summarize','holdout','refine']);p.add_argument('--report',type=Path);p.add_argument('--output',type=Path);p.add_argument('--variant',choices=VARIANTS+REFINEMENTS);a=p.parse_args()
    if a.command=='prepare':prepare()
    elif a.command=='refine':refine()
    elif a.command=='holdout':prepare_holdout(a.variant)
    else:summarize(a.report,a.output)
