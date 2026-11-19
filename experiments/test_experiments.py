"""Offline regression for Python experiment behavior; never calls a real model."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'experiments'))
sys.path.insert(0, str(ROOT / 'experiments/decision'))
sys.path.insert(0, str(ROOT / 'experiments/writer'))
sys.path.insert(0, str(ROOT / 'experiments/assistant'))
from utils import runtime
from evaluate_decision import cases_from, evaluate_case, strict_label
from workflow_scoring import parse_actions, score_turn
from workspace import Workspace, safe_path
import evaluate_writer
import evaluate_qwen


class FakeChat:
    def __init__(self, responses):self.responses=iter(responses);self.messages=[]
    async def chat(self,messages):
        self.messages.append(json.loads(json.dumps(messages)))
        return {'text':next(self.responses)}


class ExperimentTests(unittest.TestCase):
    def test_python_boundary(self):
        forbidden=[]
        for p in (ROOT/'experiments').rglob('*'):
            if any(part.startswith('.') or part=='__pycache__' for part in p.relative_to(ROOT).parts):continue
            if p.suffix in ('.swift','.sh') or p.name=='Package.resolved':forbidden.append(str(p))
        self.assertEqual(forbidden,[])

    def test_all_frozen_decision_requests_load_without_app(self):
        for name in ['gemma-decision-cases.json','apple-baseline-cases.json','binary-native-cases.json',
                     'd3-business-cases.json','decision-language-scenarios-2026-11-14.json',
                     'decision-multi-noul-2026-11-18-input.json','decision-prompt-optimization-input-2026-11-16.json']:
            with self.subTest(name=name):
                rows=cases_from(json.loads((ROOT/'experiments/decision/datasets'/name).read_text()))
                self.assertTrue(rows)
                self.assertEqual(len({r['id'] for r in rows}),len(rows))

    def test_strict_label_rejects_explanations(self):
        labels={'A':'interrupt','B':'discard','C':'enqueue'}
        self.assertEqual(strict_label(' A\n',labels),'interrupt')
        for text in ['', 'A because','1','a','{"choice":"A"}']:
            self.assertIsNone(strict_label(text,labels))

    def test_decision_chat_never_receives_labels(self):
        model=FakeChat(['B'])
        case=cases_from({'rows':[{'scenario':{'id':'x','expected':'discard'},'request':{
            'text':'Hello','instructions':'Classify','candidates':['stop','noise','reply'],'actions':['interrupt','discard','enqueue']}}]})[0]
        result=asyncio.run(evaluate_case(case,chat=model))
        self.assertTrue(result['passed']);self.assertNotIn('expected',json.dumps(model.messages))

    def test_boolean_tie_is_false_and_invalid_scores_fail(self):
        class Native:
            async def predict(self,text,question):return {'noul':.5}
        case=cases_from([{'text':'hello','expected':False}])[0]
        self.assertTrue(asyncio.run(evaluate_case(case,native=Native()))['passed'])

    def test_action_order_and_parameters_are_scored(self):
        calls=parse_actions('<wait><openCamera/></wait><wait><takePhoto countdown="3"/></wait>',0,{'openCamera','takePhoto'})
        expected={'required':['takePhoto'],'ordered':['openCamera','takePhoto'],'parameters':{'takePhoto':{'countdown':'3'}}}
        self.assertEqual(score_turn(expected,calls,{'loaded':[]}),[])
        self.assertTrue(score_turn(expected,list(reversed(calls)),{'loaded':[]}))
        with self.assertRaises(ValueError):parse_actions('<unknown/>',0,{'openCamera'})

    def test_assistant_plain_text_finishes_without_feedback_loop(self):
        model=FakeChat(['Hello'])
        result=asyncio.run(evaluate_qwen.evaluate_case({'id':'x','turns':[{'user':'hi'}]},model,
            {'system':'test','actions':['speak']},2))
        self.assertTrue(result['passed']);self.assertEqual(result['requests'],1)

    def test_workspace_enforces_relative_paths_and_exact_patch(self):
        for path in ['/tmp/a','../a','a/../../b','C:\\a']:
            with self.assertRaises(ValueError):safe_path(path)
        case={'id':'patch','goal':'patch','entry':'a.txt','resumeSeed':'seed','seeds':[
            {'name':'seed','title':'seed','entry':'a.txt','files':{'a.txt':'old','keep.txt':'keep'}}],
            'exactReplacement':{'path':'a.txt','old':'old','new':'new'},'unchangedFiles':['keep.txt']}
        workspace=Workspace(case)
        workspace.execute({'command':'replace','path':'a.txt','old':'old','new':'new'})
        workspace.execute({'command':'finish'})
        self.assertEqual(workspace.score()[0],[])
        workspace.projects['seed']['files']['keep.txt']='broken'
        self.assertIn('changedFile:keep.txt',workspace.score()[0])

    def test_writer_runs_commands_and_never_exposes_expected_content(self):
        responses=[{'command':'workspace.create','name':'new','entry':'note.txt'},
                   {'command':'edit','path':'note.txt','content':'hello'}, {'command':'finish'}]
        model=FakeChat([json.dumps(r) for r in responses])
        result=asyncio.run(evaluate_writer.evaluate_case({'id':'x','goal':'write greeting','entry':'note.txt',
            'contains':{'note.txt':['hello']}},model,'system',4))
        self.assertTrue(result['passed']);self.assertNotIn('contains',json.dumps(model.messages))

    def test_runtime_keeps_failures_and_does_not_overwrite(self):
        async def evaluate(case):
            if case['id']=='bad':raise ValueError('failure')
            return {'passed':True}
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'result.json'
            self.assertEqual(asyncio.run(runtime.run_cases([{'id':'ok'},{'id':'bad'}],evaluate,output)),1)
            report=json.loads(output.read_text());self.assertTrue(report['complete'])
            self.assertEqual(report['summary']['count'],2);self.assertEqual(report['summary']['errors'],1)
            with self.assertRaises(FileExistsError):asyncio.run(runtime.run_cases([{'id':'ok'}],evaluate,output))

    def test_invalid_model_output_retains_evidence(self):
        result=asyncio.run(evaluate_writer.evaluate_case({'id':'x','goal':'write','entry':'note.txt'},
            FakeChat(['not json']),'system',2))
        self.assertFalse(result['passed']);self.assertEqual(result['requests'][0]['response']['text'],'not json')
        result=asyncio.run(evaluate_qwen.evaluate_case({'id':'x','turns':[{'user':'hello'}]},
            FakeChat(['<invalid/>']),{'system':'system','actions':[]},2))
        self.assertFalse(result['passed']);self.assertEqual(result['turns'][0]['responses'][0]['text'],'<invalid/>')

    def test_ambiguous_probes_do_not_enter_accuracy(self):
        rows=[dict(passed=False,scored=False,milliseconds=1),dict(passed=True,milliseconds=2)]
        result=runtime.summary(rows)
        self.assertEqual(result['count'],2);self.assertEqual(result['scored'],1)
        self.assertEqual(result['passed'],1);self.assertEqual(result['excluded'],1)

    def test_timeout_is_failure(self):
        async def blocked(case):await asyncio.sleep(10)
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'result.json'
            self.assertEqual(asyncio.run(runtime.run_cases([{'id':'slow'}],blocked,output,timeout=.001)),1)
            self.assertEqual(json.loads(output.read_text())['rows'][0]['error'],'TimeoutError')


if __name__=='__main__':unittest.main()
