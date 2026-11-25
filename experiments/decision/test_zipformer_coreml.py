import hashlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from . import zipformer_coreml as coreml


class ZipformerReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.content = b"VALUE = 42\n"
        self.entry = {
            "bytes": len(self.content),
            "sha256": hashlib.sha256(self.content).hexdigest(),
        }
        self.spec = {"repository": "hugging-mac/example", "revision": "fixed",
                     "files": {"spotter.py": self.entry}}

    def test_download_uses_pinned_url_and_reuses_verified_cache(self):
        with patch.object(coreml, "MODEL_ROOT", self.root), patch.object(
            coreml, "urlopen", return_value=io.BytesIO(self.content)
        ) as fetch:
            release = coreml.prepare_release(self.spec)
            self.assertEqual(release, coreml.prepare_release(self.spec))
        fetch.assert_called_once_with(
            "https://huggingface.co/hugging-mac/example/resolve/fixed/spotter.py", timeout=60
        )
        self.assertEqual(coreml.load_host(release, self.spec).VALUE, 42)

    def test_bad_download_keeps_existing_file_and_cleans_staging(self):
        release = self.root / "fixed"
        release.mkdir()
        path = release / "spotter.py"
        invalid = self.content.replace(b"42", b"43")
        path.write_bytes(invalid)
        with patch.object(coreml, "MODEL_ROOT", self.root), patch.object(
            coreml, "urlopen", return_value=io.BytesIO(invalid)
        ), self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            coreml.prepare_release(self.spec)
        self.assertEqual(path.read_bytes(), invalid)
        self.assertEqual(list(release.iterdir()), [path])

    def test_local_override_rejects_unverified_python_without_execution(self):
        path = self.root / "spotter.py"
        path.write_bytes(self.content.replace(b"42", b"43"))
        with patch.object(coreml, "urlopen") as fetch:
            with self.assertRaisesRegex(ValueError, "Invalid pinned Core ML file"):
                coreml.prepare_release(self.spec, self.root)
            fetch.assert_not_called()
        with self.assertRaisesRegex(ValueError, "host SHA-256 mismatch"):
            coreml.load_host(self.root, self.spec)

    def test_symlink_is_rejected_even_when_target_matches(self):
        original = self.root / "original.py"
        original.write_bytes(self.content)
        (self.root / "spotter.py").symlink_to(original)
        with self.assertRaisesRegex(ValueError, "Unexpected symlink"):
            coreml.prepare_release(self.spec, self.root)
