import contextlib
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_install', Path(__file__).parents[1] / 'scripts/local_install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='macslim-install-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def app(self, root, content=b'original', bundle_id='com.macslim.cleaner'):
        (root / 'Contents/MacOS').mkdir(parents=True)
        (root / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id}))
        binary = root / 'Contents/MacOS/MacSlim'
        binary.write_bytes(content)
        binary.chmod(0o755)
        (root / 'Contents/link').symlink_to('MacOS/MacSlim')
        return root

    def test_bundle_fingerprint_survives_move_and_detects_change(self):
        source = self.app(self.root / '原始 应用.app')
        before = installer.tree(source)
        moved = self.root / 'moved.app'
        source.rename(moved)
        self.assertEqual(before, installer.tree(moved))
        (moved / 'Contents/MacOS/MacSlim').write_bytes(b'changed')
        self.assertNotEqual(before, installer.tree(moved))

    def test_verified_archive_preserves_bytes_modes_and_symlinks(self):
        source = self.app(self.root / 'MacSlim.app')
        backup = self.root / 'backup'; backup.mkdir()
        record = installer.archive_app(source, backup)
        self.assertTrue(source.exists())
        archive = Path(record['archive'])
        self.assertTrue(archive.is_file())
        self.assertEqual(record['sha256'], installer.sha(archive))
        self.assertEqual(list(backup.glob('*.app')), [])

    def test_archive_rejects_unrelated_application(self):
        source = self.app(self.root / 'Other.app', bundle_id='com.example.other')
        backup = self.root / 'backup'; backup.mkdir()
        with self.assertRaises(RuntimeError):
            installer.archive_app(source, backup)
        self.assertTrue(source.exists())
        self.assertEqual(list(backup.iterdir()), [])

    def test_wrong_dmg_never_reaches_installation(self):
        dmg = self.root / 'wrong.dmg'; dmg.write_bytes(b'wrong')
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps({'sha256': '0'*64, 'sizeBytes': 5, 'sourceCommit': 'a'*40}))
        with self.assertRaises(RuntimeError):
            installer.validate_source(dmg, manifest)

    def test_missing_source_commit_rejected(self):
        dmg = self.root / 'sample.dmg'; dmg.write_bytes(b'payload')
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps({'sha256': installer.sha(dmg), 'sizeBytes': 7}))
        with self.assertRaises(RuntimeError):
            installer.validate_source(dmg, manifest)

    def test_bundle_identity_rejected_before_running_executable(self):
        app = self.app(self.root / 'Other.app', bundle_id='com.example.other')
        with patch.object(installer, 'run') as command:
            with self.assertRaises(RuntimeError):
                installer.validate_bundle(app, {'version': '1.1.1-beta.1', 'buildNumber': 111, 'sourceCommit': 'a'*40})
            command.assert_not_called()

    def test_launch_failure_restores_previous_installed_bundle(self):
        applications = self.root / 'Applications'; applications.mkdir()
        canonical = self.app(applications / 'MacSlim.app')
        original = installer.tree(canonical)
        image = self.root / 'image'; image.mkdir()
        self.app(image / 'MacSlim.app', content=b'new release')
        home = self.root / 'Home'; home.mkdir()
        dmg = self.root / 'release.dmg'; dmg.write_bytes(b'fixture')
        manifest = self.root / 'release-manifest.json'
        manifest.write_text(json.dumps({'sha256': installer.sha(dmg), 'sizeBytes': 7, 'sourceCommit': 'a'*40, 'version': '1.1.1-beta.1', 'buildNumber': 111}))
        real_run = installer.run

        def command(*args, **kwargs):
            if str(args[0]) == '/fixture/helper':
                if args[1] == 'inventory':
                    return '[]'
                if args[1] == 'launch':
                    raise RuntimeError('simulated launch failure')
                return ''
            if str(args[0]) == installer.REGISTRY:
                return ''
            return real_run(*args, **kwargs)

        @contextlib.contextmanager
        def mounted(_):
            yield image

        import argparse
        args = argparse.Namespace(dmg=dmg, manifest=manifest, helper='/fixture/helper', receipt=self.root/'receipt.json')
        copies = [{'path': str(canonical), 'id': 'com.macslim.cleaner', 'version': 'old', 'build': '100'}]
        with patch.object(installer, 'REVIEW_BUILDS', self.root / 'unused'), patch.object(installer, 'CANONICAL', canonical), patch.object(installer, 'inventory', return_value=copies), \
             patch.object(installer, 'mounted', mounted), patch.object(installer, 'validate_bundle'), \
             patch.object(installer, 'unregister'), patch.object(installer, 'run', command), patch.object(Path, 'home', return_value=home):
            with self.assertRaisesRegex(RuntimeError, 'simulated launch failure'):
                installer.install(args)
        self.assertEqual(original, installer.tree(canonical))
        self.assertFalse(Path(args.receipt).exists())
        self.assertTrue(list(home.rglob('*.zip')))


if __name__ == '__main__':
    unittest.main()
