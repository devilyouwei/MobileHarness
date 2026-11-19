"""Writer model cases with Python-owned synthetic workspace tools and scoring."""
import argparse
import asyncio
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.runtime import chat_model, digest, positive, run_cases
from workspace import Workspace


async def evaluate_case(case, model, prompt, request_limit):
    workspace = Workspace(case)
    messages = [dict(role='system',content=prompt), dict(role='user',content=case['goal'])]
    # Only factual state is exposed, never labels or expected commands/content.
    messages.insert(1, dict(role='system',content='Synthetic workspace state: ' + json.dumps(dict(
        selected=workspace.selected, projects=[dict(name=n,title=p['title'],entry=p['entry']) for n,p in workspace.projects.items()],
        hostEvent=case.get('hostEvent')), ensure_ascii=False)))
    trace = []; resumed = False; protocol_issues = []
    for _ in range(request_limit):
        response = await model.chat(messages)
        text = response['text']; messages.append(dict(role='assistant',content=text))
        try:
            call = json.loads(text)
            if not isinstance(call,dict):raise ValueError('Expected one command object')
        except ValueError:
            trace.append(dict(response=response)); protocol_issues.append('invalidCommandJSON'); break
        try:
            feedback = workspace.execute(call)
            if call['command'] == 'render' and workspace.selected:
                project = workspace.projects[workspace.selected]
                if project['entry'].endswith('.html'):
                    from render_review import review
                    feedback['diagnostics'] = await review(project['files'], project['entry'], counter=case.get('counter', False))
        except (ValueError, KeyError, TypeError) as error:
            feedback = dict(error=str(error))
        except Exception as error:
            feedback = dict(error=type(error).__name__)
            protocol_issues.append('rendererUnavailable')
        trace.append(dict(response=response, feedback=feedback))
        if workspace.status == 'completed' and case.get('resumes') and not resumed:
            resumed = True; workspace.status = 'running'
            messages.append(dict(role='user', content=case['resumes']))
            continue
        if workspace.status in ('completed','waiting','cancelled'):break
        messages.append(dict(role='user',content='Synthetic tool result: ' + json.dumps(feedback,ensure_ascii=False)))
    issues, files = workspace.score()
    issues += protocol_issues
    if workspace.status == 'running':issues.append('requestLimit')
    visual = None
    if any(case.get(k) for k in ('domContains','diagram','counter')) and files:
        from render_review import review
        try:visual = await review(files, case['entry'], counter=case.get('counter',False))
        except Exception as error:
            visual = dict(text='',diagram=False,counterChanged=False,errors=[type(error).__name__])
        for value in case.get('domContains',[]):
            if value not in visual['text']:issues.append('domContains:' + value)
        if case.get('diagram') and not visual['diagram']:issues.append('diagram')
        if case.get('counter') and not visual['counterChanged']:issues.append('counter')
        if visual['errors']:issues.append('renderErrors')
    return dict(passed=not issues, issues=issues, commands=workspace.commands, status=workspace.status,
                files=files, requests=trace, rendering=visual, scope='Python synthetic tools; browser rendering is not App UI acceptance')


async def run(args):
    doc = json.loads(args.input.read_text()); cases = doc if isinstance(doc,list) else doc['cases']
    if args.cases:
        selected = set(args.cases.split(','))
        if not selected.issubset({c['id'] for c in cases}):raise ValueError('Unknown case')
        cases = [c for c in cases if c['id'] in selected]
    config = json.loads(args.prompt.read_text())
    model = await chat_model(json.loads(args.config.read_text()), args.timeout)
    return await run_cases(cases, lambda c: evaluate_case(c, model, config['system'], args.request_limit),
        args.output, timeout=args.timeout, provenance=dict(inputSHA256=digest(args.input),
            promptSHA256=digest(args.prompt), configSHA256=digest(args.config), runnerSHA256=digest(__file__)))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path,default=Path(__file__).parent/'datasets/writer-workflows.json')
    p.add_argument('--prompt',type=Path,default=Path(__file__).parent/'writer-evaluation.json')
    p.add_argument('--config',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--cases');p.add_argument('--request-limit',type=positive,default=24)
    p.add_argument('--timeout',type=positive,default=300)
    args=p.parse_args()
    if args.output.exists():p.error('Output must be new')
    return asyncio.run(run(args))


if __name__=='__main__':raise SystemExit(main())
