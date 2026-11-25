import asyncio
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evaluate_quiet_exit as quiet

HERE = Path(__file__).resolve().parent
PROMPTS = json.loads((HERE / 'quiet-exit-prompts.json').read_text())
DATASET = json.loads((HERE / 'datasets' / 'quiet-exit-cases-2026-11-23.json').read_text())
CURRENT_PROMPTS = json.loads((HERE / 'quiet-exit-current-prompts-2026-11-25.json').read_text())
CURRENT_DATASET = json.loads((HERE / 'datasets' / 'quiet-exit-current-cases-2026-11-25.json').read_text())


class Chat:
    def __init__(self, text):
        self.text, self.messages = text, None

    async def chat(self, messages):
        self.messages = messages
        return dict(text=self.text)


class Native:
    def __init__(self, score):
        self.score, self.call = score, None

    async def predict(self, text, question):
        self.call = (text, question)
        return dict(type='noul', noul=self.score)


class QuietExitTests(unittest.TestCase):
    def test_dataset_is_valid_balanced_and_labels_stay_out_of_requests(self):
        cases = quiet.load_cases(DATASET)
        scored = [c for c in cases if c.get('partition') != 'ambiguous']
        self.assertGreaterEqual(len(scored), 80)
        self.assertEqual({c['language'] for c in cases}, {'en', 'zh-Hans'})
        for expected in quiet.LABELS:
            self.assertGreaterEqual(sum(c['expected'] == expected for c in scored), 30)
        self.assertEqual({c['group'] for c in cases}, set(DATASET['groups']))
        chat = Chat('stay')
        asyncio.run(quiet.evaluate_case(cases[0], PROMPTS, chat=chat))
        self.assertEqual([m['role'] for m in chat.messages], ['system', 'user'])
        self.assertEqual(chat.messages[1]['content'], cases[0]['sentence'])
        self.assertNotIn(cases[0]['group'], json.dumps(chat.messages))

    def test_historical_answers_allow_explanations(self):
        self.assertEqual(quiet.parse_answer('exit'), ('exit', None))
        self.assertEqual(quiet.parse_answer('  Stay. '), ('stay', None))
        self.assertEqual(quiet.parse_answer('exit: the user invites me'), ('exit', 'the user invites me'))
        for bad in ['', 'maybe', 'I think exit', '1', '"exit"']:
            self.assertEqual(quiet.parse_answer(bad), (None, None))

    def test_boolean_prompts_parse_true_false_as_exit_stay(self):
        self.assertEqual(quiet.parse_boolean('true'), ('exit', None))
        self.assertEqual(quiet.parse_boolean(' False. '), ('stay', None))
        self.assertEqual(quiet.parse_boolean('true - invited'), ('exit', 'invited'))
        for bad in ['', 'exit', 'yes', '...']:
            self.assertEqual(quiet.parse_boolean(bad), (None, None))
        wake = json.loads((HERE / 'quiet-wake-prompts.json').read_text())
        self.assertEqual(wake['answer'], 'boolean')
        case = dict(id='x', language='en', group='exit_call', sentence='Hey, are you there?', expected='exit')
        row = asyncio.run(quiet.evaluate_case(case, wake, chat=Chat('true')))
        self.assertTrue(row['passed'] and row['prediction'] == 'exit')
        self.assertFalse(asyncio.run(quiet.evaluate_case(case, wake, chat=Chat('stay')))['passed'])

    def test_chat_case_scores_and_flags_invalid_answers(self):
        case = dict(id='x', language='zh-Hans', group='exit_invite', sentence='好了，你可以说话了。', expected='exit')
        row = asyncio.run(quiet.evaluate_case(case, PROMPTS, chat=Chat('exit 被邀请')))
        self.assertTrue(row['passed'] and row['prediction'] == 'exit' and row['reason'] == '被邀请')
        bad = asyncio.run(quiet.evaluate_case(case, PROMPTS, chat=Chat('好的')))
        self.assertFalse(bad['passed'])
        self.assertEqual(bad['issues'], ['invalidAnswer'])

    def test_native_case_uses_a_boolean_question_over_a_one_field_state(self):
        case = dict(id='x', language='en', group='stay_continue', sentence='So then I went home.', expected='stay')
        native = Native(.2)
        row = asyncio.run(quiet.evaluate_case(case, PROMPTS, native=native))
        self.assertTrue(row['passed'])
        text, question = native.call
        self.assertEqual(json.loads(text), dict(latest_user_sentence='So then I went home.'))
        self.assertEqual(question, dict(type='noul', instructions=PROMPTS['decision']['en']))
        self.assertFalse(asyncio.run(quiet.evaluate_case(case, PROMPTS, native=Native(.9)))['passed'])

    def test_current_default_sends_only_sentence_and_tie_stays(self):
        case = quiet.load_cases(CURRENT_DATASET)[0]
        native = Native(.5)
        row = asyncio.run(quiet.evaluate_case(case, CURRENT_PROMPTS, native=native))
        self.assertEqual(row['prediction'], 'stay')
        self.assertEqual(native.call, (case['sentence'], {
            'type': 'noul', 'instructions': CURRENT_PROMPTS['decision'][case['language']]['instructions'],
        }))

    def test_current_conditioned_request_contains_only_condition_and_utterance(self):
        case = next(c for c in quiet.load_cases(CURRENT_DATASET) if 'wakeCondition' in c)
        native = Native(.9)
        chat = Chat('  EXIT  ')
        self.assertEqual(asyncio.run(quiet.evaluate_case(case, CURRENT_PROMPTS, chat=chat))['prediction'], 'exit')
        asyncio.run(quiet.evaluate_case(case, CURRENT_PROMPTS, native=native))
        self.assertEqual(chat.messages[0]['content'], CURRENT_PROMPTS['chat'][case['language']]['conditioned'])
        self.assertEqual(native.call[1]['instructions'], CURRENT_PROMPTS['decision'][case['language']]['conditioned'])
        self.assertEqual(native.call[0], chat.messages[1]['content'])
        self.assertEqual(json.loads(native.call[0]), {
            'wakeCondition': case['wakeCondition'], 'latestUtterance': case['sentence'],
        })
        for answer in ('exit because they called', 'stay.', 'true'):
            row = asyncio.run(quiet.evaluate_case(case, CURRENT_PROMPTS, chat=Chat(answer)))
            self.assertEqual(row['issues'], ['invalidAnswer'])

    def test_metrics_separate_false_wakes_from_missed_exits_and_skip_ambiguous(self):
        rows = [
            dict(scored=True, group='a', expected='stay', prediction='exit', passed=False),
            dict(scored=True, group='a', expected='stay', prediction='stay', passed=True),
            dict(scored=True, group='b', expected='exit', prediction='stay', passed=False),
            dict(scored=True, group='b', expected='exit', prediction=None, passed=False),
            dict(scored=False, group='c', expected='exit', prediction='exit', passed=True),
            dict(scored=True, group='b', expected='exit', error='TimeoutError', passed=False),
        ]
        m = quiet.metrics(rows)
        self.assertEqual((m['scoredCases'], m['falseWake'], m['missedExit'], m['invalid'], m['errors']), (4, 1, 1, 1, 1))
        self.assertEqual((m['falseWakeRate'], m['missedExitRate']), (.5, .5))


if __name__ == '__main__':
    unittest.main()
