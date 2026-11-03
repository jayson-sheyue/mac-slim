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
        self.root = Path(self.temp.name).resolve()

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
                installer.validate_bundle(app, {'version': '1.1.1-beta.2', 'buildNumber': 111, 'sourceCommit': 'a'*40})
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
        manifest.write_text(json.dumps({'sha256': installer.sha(dmg), 'sizeBytes': 7, 'sourceCommit': 'a'*40, 'version': '1.1.1-beta.2', 'buildNumber': 111}))
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


    def test_success_ignores_only_its_own_temporary_rollback_bundle(self):
        applications = self.root / 'Applications'; applications.mkdir()
        canonical = self.app(applications / 'MacSlim.app')
        image = self.root / 'image'; image.mkdir()
        source = self.app(image / 'MacSlim.app', content=b'new release')
        expected = installer.tree(source)
        home = self.root / 'Home'; home.mkdir()
        dmg = self.root / 'release.dmg'; dmg.write_bytes(b'fixture')
        manifest = self.root / 'release-manifest.json'
        metadata = {'sha256': installer.sha(dmg), 'sizeBytes': 7, 'sourceCommit': 'a'*40, 'version': '1.1.1-beta.2', 'buildNumber': 112}
        manifest.write_text(json.dumps(metadata))
        real_run = installer.run

        def command(*args, **kwargs):
            if str(args[0]) == '/fixture/helper':
                return '[]' if args[1] == 'inventory' else ''
            if str(args[0]) in {installer.REGISTRY, str(canonical / 'Contents/MacOS/MacSlim')}:
                return ''
            return real_run(*args, **kwargs)

        def inventory(_):
            paths = [canonical, *applications.glob('.MacSlim-install-*/old.app')]
            return [{'path': str(path), 'id': 'com.macslim.cleaner'} for path in paths]

        @contextlib.contextmanager
        def mounted(_):
            yield image

        import argparse
        args = argparse.Namespace(dmg=dmg, manifest=manifest, helper='/fixture/helper', receipt=self.root/'receipt.json')
        with patch.object(installer, 'REVIEW_BUILDS', self.root / 'unused'), patch.object(installer, 'CANONICAL', canonical), \
             patch.object(installer, 'inventory', inventory), patch.object(installer, 'mounted', mounted), \
             patch.object(installer, 'validate_bundle'), patch.object(installer, 'unregister'), \
             patch.object(installer, 'wait_identity', return_value={'pid': '123'}), patch.object(installer, 'run', command), \
             patch.object(Path, 'home', return_value=home), patch('builtins.print'):
            installer.install(args)
        self.assertEqual(expected, installer.tree(canonical))
        self.assertTrue(Path(args.receipt).exists())
        self.assertEqual(list(applications.glob('.MacSlim-install-*')), [])
        self.assertTrue(list(home.rglob('*.zip')))

    def test_image_detach_retries_only_temporary_busy_errors(self):
        busy = subprocess.CalledProcessError(16, ['hdiutil', 'detach'], stderr='Resource busy')
        with patch.object(installer, 'run', side_effect=[busy, '']) as command, patch.object(installer.time, 'sleep') as pause:
            installer.detach_image(self.root / 'image')
        self.assertEqual(command.call_count, 2)
        pause.assert_called_once_with(1)
        denied = subprocess.CalledProcessError(1, ['hdiutil', 'detach'], stderr='permission denied')
        with patch.object(installer, 'run', side_effect=denied) as command, patch.object(installer.time, 'sleep') as pause:
            with self.assertRaisesRegex(RuntimeError, 'temporary mount retained'):
                installer.detach_image(self.root / 'image')
        self.assertEqual(command.call_count, 1)
        pause.assert_not_called()

    def test_permanently_busy_mount_is_retained_without_recursive_cleanup(self):
        directory = self.root / 'mount-work'; directory.mkdir()
        mountpoint = directory / 'image'; mountpoint.mkdir()
        sentinel = mountpoint / 'MacSlim.app'; sentinel.mkdir()
        busy = subprocess.CalledProcessError(16, ['hdiutil', 'detach'], stderr='Resource busy')
        def command(*args, **kwargs):
            if args[1] == 'detach':
                raise busy
            return ''
        with patch.object(installer.tempfile, 'mkdtemp', return_value=str(directory)), patch.object(installer, 'run', command), \
             patch.object(installer.time, 'sleep'), patch.object(installer.shutil, 'rmtree') as remove:
            with self.assertRaisesRegex(RuntimeError, 'temporary mount retained'):
                with installer.mounted(self.root / 'release.dmg'):
                    pass
            remove.assert_not_called()
        self.assertTrue(sentinel.is_dir())

if __name__ == '__main__':
    unittest.main()
