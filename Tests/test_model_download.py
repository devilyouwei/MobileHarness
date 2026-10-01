"""Pinned ZIP provisioning tests; no network or model weights required."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from model_download import install_archive


class ModelArchiveTests(unittest.TestCase):
    def fixture(self, root, symlink=False):
        name = 'sample.mlpackage/Manifest.json'
        data = b'{"model":"fixture"}'
        archive = root / 'model.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            entry = zipfile.ZipInfo(name)
            if symlink:
                entry.create_system = 3
                entry.external_attr = 0o120777 << 16
            package.writestr(entry, data)
        config = {'archive': {'size': archive.stat().st_size, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()},
                  'files': [name], 'sha256': {name: hashlib.sha256(data).hexdigest()}}
        return archive, config, name

    def test_install_and_replace_verified_package(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive, config, name = self.fixture(root)
            target = root / 'installed'
            install_archive(config, archive, target)
            self.assertEqual(json.loads((target/name).read_text()), {'model': 'fixture'})
            (target/name).write_text('damaged')
            install_archive(config, archive, target)
            self.assertEqual(json.loads((target/name).read_text()), {'model': 'fixture'})
            self.assertEqual(list(target.glob('.model-stage-*')), [])

    def test_invalid_archive_or_member_preserves_existing_model(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive, config, name = self.fixture(root)
            target = root / 'installed'
            install_archive(config, archive, target)
            original = (target/name).read_bytes()
            config['sha256'][name] = '0' * 64
            with self.assertRaises(ValueError):
                install_archive(config, archive, target)
            self.assertEqual((target/name).read_bytes(), original)
            config['archive']['sha256'] = '0' * 64
            with self.assertRaises(ValueError):
                install_archive(config, archive, target)
            self.assertEqual((target/name).read_bytes(), original)

    def test_rejects_symlink_and_traversal(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive, config, _ = self.fixture(root, symlink=True)
            with self.assertRaises(ValueError):
                install_archive(config, archive, root/'installed')
            config['files'] = ['../escape.mlpackage/Manifest.json']
            with self.assertRaises(ValueError):
                install_archive(config, archive, root/'installed')


if __name__ == '__main__':
    unittest.main()
