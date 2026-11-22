import importlib
import importlib.util
import sys
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "evaluate_qwen", next(p for p in Path(__file__).resolve().parents if (p / 'experiments').is_dir()) / "experiments/assistant/evaluate_qwen.py")
sys.path.insert(0, str(Path(__file__).resolve().parent))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class QwenRunnerTests(unittest.TestCase):
    def test_selection_rejects_empty_and_unknown_before_network(self):
        cases = [{"id": "one"}, {"id": "two"}]
        self.assertEqual(evaluation.selected_ids(cases, None), {"one", "two"})
        self.assertEqual(evaluation.selected_ids(cases, "one"), {"one"})
        for invalid in ("", "one,", "unknown"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                evaluation.selected_ids(cases, invalid)

    def test_env_selects_only_aliyun_without_shell_evaluation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "environment"
            path.write_text("OPENAI_API_KEY=not-used\n"
                            "export ALIYUN_API_URL='https://example.invalid/v1'\n"
                            "ALIYUN_API_KEY=literal-$(never-execute)\n")
            self.assertEqual(evaluation.read_aliyun_env(path), {
                "ALIYUN_API_URL": "https://example.invalid/v1",
                "ALIYUN_API_KEY": "literal-$(never-execute)",
            })
            path.write_text("ALIYUN_API_URL=https://example.invalid/v1\n")
            with self.assertRaises(ValueError):
                evaluation.read_aliyun_env(path)


    def test_state_controls_mirror_app_rules(self):
        scoring = importlib.import_module("workflow_scoring")
        state = {"loaded": [], "variables": {}}
        run = lambda xml: scoring.apply_actions(scoring.parse_actions(xml, 0, {"state.set", "state.clear", "state.get", "send"}), state)
        self.assertEqual(run('<state.set name="task" value="goal"/>')[0].get("void"), True)
        self.assertTrue(state["task"])
        # Replacing or clearing a held task requires a note; the rejection is recorded and the value is unchanged.
        self.assertEqual(run('<state.clear name="task"/>')[0]["status"], "failed")
        self.assertEqual(state["variables"]["task"], "goal")
        self.assertEqual(run('<state.set name="quiet" value="false"/>')[0]["status"], "failed")
        self.assertEqual(run('<state.set name="agent.writer" value="x"/>')[0]["status"], "failed")
        self.assertEqual(run('<state.get path="task"/>')[0]["result"]["value"], "goal")
        run('<state.clear name="task" note="done"/>')
        self.assertFalse(state["task"])
        issues = scoring.score_turn({"variables": {"task": None}}, [], state)
        self.assertEqual(issues, ["rejected:state.clear:noteRequired"])
        self.assertEqual(scoring.score_turn({"allowRejections": True, "variables": {"task": None}}, [], state), [])

    def test_dataset_uses_only_declared_controls(self):
        here = Path(__file__).parent
        configuration = json.loads((here / "assistant-evaluation.json").read_text())
        known = set(configuration["actions"])
        for case in json.loads((here / "datasets/qwen-workflows.json").read_text())["cases"]:
            for turn in case["turns"]:
                names = set(turn.get("required", []) + turn.get("forbidden", []) + turn.get("ordered", []))
                names |= set(turn.get("parameters", {})) | set(turn.get("forbiddenParameters", {}))
                self.assertLessEqual(names, known, case["id"])


if __name__ == "__main__":
    unittest.main()
