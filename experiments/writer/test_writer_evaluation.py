"""Offline regression for the Writer runner's configured matrix entry point."""
import json
from pathlib import Path
import unittest

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "experiments").is_dir())


class WriterEvaluationConfigurationTests(unittest.TestCase):
    def test_matrix_configuration_resolves_a_task_owned_case_set(self):
        configuration = json.loads((ROOT / "experiments/writer/writer-evaluation.json").read_text())
        path = (ROOT / configuration["scenarioFile"]).resolve()
        self.assertEqual(path.parent, ROOT / "experiments/writer/datasets")
        matrix = json.loads(path.read_text())
        self.assertTrue(matrix["cases"])
        self.assertEqual(len(matrix["cases"]), len({item["id"] for item in matrix["cases"]}))
