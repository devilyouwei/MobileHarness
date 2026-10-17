import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "evaluate_qwen", Path(__file__).resolve().parent.parent / "scripts/evaluate-qwen.py")
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

    def test_compact_evidence_accepts_array_and_object_messages(self):
        messages = [{"role": "system", "content": "stable"},
                    {"role": "system", "content": "# CURRENT STATE\n{}"}]
        for request in (messages, {"messages": messages}):
            with self.subTest(request=request):
                case = {"id": "fixture", "runtimeIssues": [], "turns": [{"issues": []}],
                        "archive": {"current": {"turns": [{
                            "user": "synthetic query", "state": "completed",
                            "modelRequests": [{"requestJSON": json.dumps(request),
                                               "response": "", "toolCalls": []}]}]}}}
                compact = evaluation.compact_case(case)
                self.assertTrue(compact["passed"])
                evidence = compact["evidence"][0]["modelRequests"][0]
                self.assertNotIn("requestJSON", evidence)
                self.assertEqual(evidence["stateMessages"], messages[1:])
                self.assertEqual(len(evidence["requestSHA256"]), 64)
                case["runtimeIssues"].append("synthetic error")
                self.assertFalse(evaluation.compact_case(case)["passed"])


if __name__ == "__main__":
    unittest.main()
