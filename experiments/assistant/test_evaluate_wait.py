import importlib.util
import json
from pathlib import Path
import unittest


ROOT = next(p for p in Path(__file__).resolve().parents if (p / "experiments").is_dir())
spec = importlib.util.spec_from_file_location("evaluate_wait", ROOT / "experiments/assistant/evaluate_wait.py")
wait = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wait)
DOCUMENT = json.loads((ROOT / "experiments/assistant/datasets/wait-prompt-cases.json").read_text())
CASES = {c["id"]: c for c in DOCUMENT["cases"]}

CORRECT = {
    "single-expression": '<express emotion="happy"/>',
    "voice-exit": "<stopListening/>",
    "speech-then-expression": '<wait>Hello.</wait><express emotion="happy"/>',
    "parallel-expression-speech": '<wait><express emotion="happy"/>Good morning.</wait>',
    "nested-three-steps": '<wait><express emotion="thinking"/><wait><express emotion="happy"/>Yes.</wait></wait><setExpression emotion="closed"/>',
    "delay-after-speech": '<wait>Ready.</wait><wait time="2"/><express emotion="happy"/>',
    "delay-between-speech": '<wait>一。</wait><wait time="2"/>二。',
    "hold-eyes-closed": '<setExpression emotion="closed"/><wait time="3"/><setExpression emotion="clear"/>',
    "subsecond-delay": '<setExpression emotion="closed"/><wait time="0.5"/><setExpression emotion="clear"/>',
    "limit-request": '<express emotion="happy"/><wait time="60"/><setExpression emotion="closed"/>',
}
WRONG = {
    "speech-then-expression": '<express emotion="happy"/>Hello.',
    "delay-between-speech": '一。<wait time="2"/>二。',
    "hold-eyes-closed": '<setExpression emotion="closed"/><wait time="3"/>',
    "nested-three-steps": '<wait><express emotion="thinking"/><express emotion="happy"/>Yes.</wait><setExpression emotion="closed"/>',
    "single-expression": '<wait><express emotion="happy"/></wait>',
    "limit-request": '<wait time="300"/>',
    "delay-after-speech": '```xml\n<wait>Ready.</wait>\n```',
}


class WaitScoringTests(unittest.TestCase):
    def test_reference_outputs_pass(self):
        for name, text in CORRECT.items():
            with self.subTest(name):
                self.assertEqual(wait.score(CASES[name], text, DOCUMENT["durations"])[0], [])

    def test_semantic_mistakes_fail(self):
        for name, text in WRONG.items():
            with self.subTest(name):
                self.assertTrue(wait.score(CASES[name], text, DOCUMENT["durations"])[0])

    def test_scope_end_blocks_and_delay_does_not(self):
        durations = DOCUMENT["durations"]
        scoped = wait.simulate(wait.parse('<wait><express emotion="happy"/></wait><setExpression emotion="closed"/>'), durations)
        self.assertEqual(scoped[1]["start"], 2)
        delayed = wait.simulate(wait.parse('<express emotion="happy"/><wait time="1"/>Hi.'), durations)
        self.assertEqual(delayed[1]["start"], 1)

    def test_grammar_rejections(self):
        for text in ('<wait/>', '<wait time="1">', '<unknown/>', '<wait time="0"/>', '<wait time="x"/>'):
            with self.subTest(text):
                try:
                    issues = wait.validate(wait.parse(text))
                except ValueError:
                    issues = ["parse"]
                self.assertTrue(issues)


if __name__ == "__main__":
    unittest.main()
