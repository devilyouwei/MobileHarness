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

class SourceCatalogTests(unittest.TestCase):
    def test_production_profiles_share_catalog_and_nemotron_is_cross_platform(self):
        from model_download import load_config
        for name in ('nemotron', 'silero', 'moss-tts-nano', 'gemma4-e2b', 'yolo26-pose'):
            config = load_config(name)
            self.assertIn('declaration', config)
            self.assertNotIn('files', config)
        mac = load_config('nemotron', 'macos')
        self.assertEqual(mac, load_config('nemotron', 'ios'))
        self.assertEqual(mac['directory'], 'Nemotron')
        self.assertEqual(mac['declaration']['stripPrefix'], 'multilingual/2240ms')
        self.assertEqual(mac['declaration']['allowPatterns'], ['multilingual/2240ms/**'])
        gemma = load_config('gemma4-e2b')
        mac_gemma = load_config('gemma4-e2b', 'macos')
        self.assertEqual(gemma['directory'], 'Gemma4')
        self.assertEqual(gemma['declaration']['revision'], mac_gemma['declaration']['revision'])
        self.assertIn('aotc_h18p', gemma['declaration']['allowPatterns'][0])
        self.assertNotIn('aotc_h18p', mac_gemma['declaration']['allowPatterns'][0])

    def test_hub_selection_prefix_metadata_and_mirror(self):
        from model_download import resolve_hub
        config = {'directory': 'Fixture', 'requiredFiles': ['model.bin'], 'declaration': {
            'repoId': 'owner/repo', 'revision': 'fixed', 'allowPatterns': ['ios/model.bin'], 'stripPrefix': 'ios'}}
        def read(url):
            self.assertTrue(url.startswith('https://hf-mirror.com/api/models/owner/repo/tree/fixed'))
            return [{'type': 'file', 'path': 'ios/model.bin', 'size': 3, 'lfs': {'size': 3, 'oid': 'a' * 64}},
                    {'type': 'file', 'path': 'macos/model.bin', 'size': 4}], None
        resolved = resolve_hub(config, 'https://hf-mirror.com', read)
        self.assertEqual(resolved['files'], ['model.bin'])
        self.assertEqual(resolved['fileSizes'], {'model.bin': 3})
        self.assertEqual(resolved['sha256'], {'model.bin': 'a' * 64})
        self.assertEqual(resolved['fileURLs']['model.bin'], 'https://hf-mirror.com/owner/repo/resolve/fixed/ios/model.bin')
        with self.assertRaises(ValueError):
            resolve_hub(config, 'https://hf-mirror.com', lambda _: ([], None))
        with self.assertRaises(ValueError):
            resolve_hub(config, 'https://hf-mirror.com', lambda _: ([], 'https://other.example/page'))

    def test_archive_catalog_uses_required_files_without_static_member_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive, legacy, name = ModelArchiveTests().fixture(root)
            config = {'archive': {'sha256': legacy['archive']['sha256']}, 'requiredFiles': [name]}
            install_archive(config, archive, root/'installed')
            self.assertTrue((root/'installed'/name).is_file())


if __name__ == '__main__':
    unittest.main()
