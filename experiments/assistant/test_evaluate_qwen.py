import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "evaluate_qwen", next(p for p in Path(__file__).resolve().parents if (p / 'experiments').is_dir()) / "experiments/assistant/evaluate_qwen.py")
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



if __name__ == "__main__":
    unittest.main()
