#!/usr/bin/env python3
"""Install and verify the exact release DMG; archive only verified MacSlim copies."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CANONICAL = Path('/Applications/MacSlim.app')
REGISTRY = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
REVIEW_BUILDS = Path('/private/tmp/macslim-review')
IDS = {'com.macslim.cleaner', 'com.macslim.fixture', 'com.macslim.fixture.dark'}


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, text=True, capture_output=True, **kwargs).stdout.strip()


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def info(path):
    return plistlib.loads((Path(path) / 'Contents/Info.plist').read_bytes())


def tree(path):
    """File bytes, symlink targets and permissions, independent of absolute paths."""
    root = Path(path)
    result = []
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            item = Path(base) / name
            relative = item.relative_to(root).as_posix()
            if item.is_symlink():
                result.append([relative, 'link', os.readlink(item)])
            elif item.is_file():
                result.append([relative, 'file', item.stat().st_mode & 0o777, sha(item)])
            elif item.is_dir():
                result.append([relative, 'dir', item.stat().st_mode & 0o777])
    return sorted(result)


def tree_sha(path):
    return hashlib.sha256(json.dumps(tree(path), ensure_ascii=False).encode()).hexdigest()


def inventory(extra=()):
    roots = [Path('/Applications'), Path.home() / 'Applications', Path.home() / 'Desktop', Path.home() / 'Downloads', Path('/private/tmp'), Path('/Volumes'), *map(Path, extra)]
    found = {}
    for root in roots:
        if not root.is_dir():
            continue
        for base, dirs, _ in os.walk(root, followlinks=False):
            if len(Path(base).relative_to(root).parts) > 8:
                dirs[:] = []
                continue
            for name in list(dirs):
                path = Path(base) / name
                if name in {'.git', '.build', 'node_modules', '.Trash'}:
                    dirs.remove(name)
                elif name.endswith('.app'):
                    dirs.remove(name)
                    if path.is_symlink():
                        continue
                    try:
                        metadata = info(path)
                    except (OSError, ValueError, plistlib.InvalidFileException):
                        continue
                    if metadata.get('CFBundleIdentifier') in IDS:
                        resolved = path.resolve()
                        found[str(resolved)] = {'path': str(resolved), 'id': metadata['CFBundleIdentifier'], 'version': metadata.get('CFBundleShortVersionString'), 'build': metadata.get('CFBundleVersion')}
    return list(found.values())


def detach_image(mountpoint):
    for attempt in range(3):
        try:
            run('/usr/bin/hdiutil', 'detach', mountpoint)
            return
        except subprocess.CalledProcessError as error:
            busy = error.returncode == 16 or 'Resource busy' in (error.stderr or '')
            if not busy or attempt == 2:
                raise RuntimeError(f'Could not detach image at {mountpoint}; temporary mount retained for safe cleanup') from error
            time.sleep(attempt + 1)


@contextmanager
def mounted(dmg):
    # Never let TemporaryDirectory recursively remove a still-mounted filesystem.
    directory = Path(tempfile.mkdtemp(prefix='macslim-mount-'))
    mountpoint = directory / 'image'
    try:
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mountpoint, dmg)
    except BaseException:
        if mountpoint.is_mount():
            detach_image(mountpoint)
        if mountpoint.exists():
            mountpoint.rmdir()
        directory.rmdir()
        raise
    try:
        yield mountpoint
    finally:
        detach_image(mountpoint)
        if mountpoint.exists():
            mountpoint.rmdir()
        directory.rmdir()


def validate_source(dmg, manifest):
    metadata = json.loads(Path(manifest).read_text())
    if sha(dmg) != metadata['sha256'] or Path(dmg).stat().st_size != metadata['sizeBytes']:
        raise RuntimeError('DMG hash or size does not match the release manifest')
    if len(metadata.get('sourceCommit', '')) != 40:
        raise RuntimeError('Release manifest has no exact source commit')
    return metadata


def validate_bundle(app, metadata):
    actual = info(app)
    expected = {'CFBundleIdentifier': 'com.macslim.cleaner', 'CFBundleShortVersionString': metadata['version'], 'CFBundleVersion': str(metadata['buildNumber']), 'MacSlimSourceCommit': metadata['sourceCommit']}
    if any(actual.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Application identity does not match the release manifest')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    run('/usr/bin/lipo', app / 'Contents/MacOS/MacSlim', '-verify_arch', 'arm64', 'x86_64')
    run(app / 'Contents/MacOS/MacSlim', '--self-check')


def archive_app(path, backup):
    path = Path(path)
    if path.is_symlink() or info(path).get('CFBundleIdentifier') not in IDS:
        raise RuntimeError(f'Unverified duplicate: {path}')
    before = tree(path)
    output = backup / (path.name + '-' + uuid.uuid4().hex[:8] + '.zip')
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', path, output)
    with tempfile.TemporaryDirectory(prefix='macslim-archive-check-') as directory:
        run('/usr/bin/ditto', '-x', '-k', output, directory)
        if tree(Path(directory) / path.name) != before:
            raise RuntimeError(f'Backup verification failed: {path}')
    if tree(path) != before:
        raise RuntimeError(f'Duplicate changed during backup: {path}')
    return {'originalPath': str(path), 'archive': str(output), 'sha256': sha(output)}


def unregister(path):
    subprocess.run([REGISTRY, '-u', str(path)], check=False, capture_output=True)


def critical_data():
    root = Path.home() / 'Library/Application Support/MacSlim'
    data = {}
    for name in ['config.json', 'recovery-v1.json', 'operations-v1.json']:
        path = root / name
        if path.exists():
            data[name] = json.loads(path.read_text())
    return data


def wait_identity(metadata, helper):
    lock = Path.home() / 'Library/Application Support/MacSlim/runtime.lock'
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        try:
            state = json.loads(lock.read_text())
            processes = json.loads(run(helper, 'inventory'))
            matching = [row for row in processes if row['id'] == 'com.macslim.cleaner']
            if len(matching) == 1 and matching[0]['path'] == str(CANONICAL) and state.get('pid') == matching[0]['pid'] and state.get('version') == metadata['version'] and state.get('sourceCommit') == metadata['sourceCommit']:
                return state
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(0.25)
    raise RuntimeError('Could not verify one running process from the canonical installation')


def install(args):
    metadata = validate_source(args.dmg, args.manifest)
    if CANONICAL.is_symlink() or (CANONICAL.exists() and info(CANONICAL).get('CFBundleIdentifier') != 'com.macslim.cleaner'):
        raise RuntimeError('Canonical destination is not a verified MacSlim installation')
    helper = Path(args.helper).resolve()
    backup = Path.home() / 'Library/Application Support/MacSlim/InstallBackups' / (metadata['version'] + '-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True, mode=0o700)
    before_data = critical_data()
    for name in before_data:
        shutil.copy2(Path.home() / 'Library/Application Support/MacSlim' / name, backup / name)
    receipt = {'version': metadata['version'], 'sourceCommit': metadata['sourceCommit'], 'dmgSHA256': metadata['sha256'], 'installedPath': str(CANONICAL), 'backups': []}
    copies = inventory([REPO])
    processes = json.loads(run(helper, 'inventory'))
    known = {row['path'] for row in copies}
    unknown = [row for row in processes if row['path'] not in known]
    if unknown:
        raise RuntimeError('Unrecognized running MacSlim instance; stop it before installing: ' + json.dumps(unknown))
    if copies:
        run(helper, 'stop', *[row['path'] for row in copies])
    # Never remove a running app or force-terminate a busy one.
    if json.loads(run(helper, 'inventory')):
        raise RuntimeError('MacSlim is still running; installation canceled')
    with mounted(args.dmg) as image, tempfile.TemporaryDirectory(prefix='.MacSlim-install-', dir=CANONICAL.parent) as staging:
        source = image / 'MacSlim.app'
        validate_bundle(source, metadata)
        expected = tree(source)
        staged = Path(staging) / 'new.app'
        old = Path(staging) / 'old.app'
        run('/usr/bin/ditto', source, staged)
        validate_bundle(staged, metadata)
        if tree(staged) != expected:
            raise RuntimeError('Staged installation differs from the DMG')
        replaced = False
        try:
            for row in copies:
                path = Path(row['path'])
                if str(path).startswith('/Volumes/'):
                    raise RuntimeError('An older MacSlim disk image is still mounted; eject it before installing')
                receipt['backups'].append(archive_app(path, backup))
            if CANONICAL.exists():
                unregister(CANONICAL)
                CANONICAL.rename(old)
            staged.rename(CANONICAL)
            replaced = True
            validate_bundle(CANONICAL, metadata)
            if tree(CANONICAL) != expected:
                raise RuntimeError('Installed app differs from the release DMG')
            for row in copies:
                path = Path(row['path'])
                if path == CANONICAL:
                    continue
                unregister(path)
                shutil.rmtree(path)
            # Archive standalone GUI binaries left by this project's previous review builds.
            temporary_builds = REVIEW_BUILDS
            if temporary_builds.is_dir():
                raw = [p for p in temporary_builds.iterdir() if p.is_file() and not p.is_symlink() and p.name.startswith('MacSlim') and os.access(p, os.X_OK)]
                for path in raw:
                    destination = backup / (path.name + '.zip')
                    original_hash = sha(path)
                    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
                        archive.write(path, path.name)
                    with zipfile.ZipFile(destination) as archive:
                        if hashlib.sha256(archive.read(path.name)).hexdigest() != original_hash:
                            raise RuntimeError('Standalone backup failed verification')
                    if sha(path) != original_hash:
                        raise RuntimeError('Standalone binary changed during backup')
                    path.unlink()
                    receipt['backups'].append({'originalPath': str(path), 'archive': str(destination), 'sha256': sha(destination)})
            run(REGISTRY, '-f', CANONICAL)
            run(helper, 'launch', CANONICAL)
            receipt['runningIdentity'] = wait_identity(metadata, helper)
            # A second direct launch must immediately exit and leave the same sole process alive.
            run(CANONICAL / 'Contents/MacOS/MacSlim', timeout=10)
            if wait_identity(metadata, helper)['pid'] != receipt['runningIdentity']['pid']:
                raise RuntimeError('Duplicate launch replaced the primary runtime')
            after_data = critical_data()
            if before_data.get('recovery-v1.json') != after_data.get('recovery-v1.json'):
                raise RuntimeError('Recovery records changed during installation')
            for key in ['minCacheSizeMB', 'minimumAgeDays']:
                if key in before_data.get('config.json', {}) and before_data['config.json'][key] != after_data.get('config.json', {}).get(key):
                    raise RuntimeError('User scan settings changed during installation')
            remaining = [row for row in inventory([REPO])
                         if row['path'] != str(old.resolve()) and not row['path'].startswith(str(image.resolve()) + '/')]
            if len(remaining) != 1 or remaining[0]['path'] != str(CANONICAL):
                raise RuntimeError('Duplicate application bundles remain after installation: ' + json.dumps(remaining))
            receipt['bundleSHA256'] = tree_sha(CANONICAL)
            receipt['verifiedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
            Path(args.receipt).write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
            (backup / 'installation-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        except BaseException:
            if replaced:
                try:
                    run(helper, 'stop', CANONICAL)
                except BaseException as error:
                    raise RuntimeError(f'Rollback could not stop the app; verified original backups remain in {backup}') from error
                shutil.rmtree(CANONICAL)
            if old.exists() and not CANONICAL.exists():
                old.rename(CANONICAL)
                run(REGISTRY, '-f', CANONICAL)
            raise
    print(json.dumps(receipt, ensure_ascii=False, indent=2))


def verify(args):
    metadata = validate_source(args.dmg, args.manifest)
    with mounted(args.dmg) as image:
        source = image / 'MacSlim.app'
        validate_bundle(source, metadata)
        if args.installed:
            validate_bundle(CANONICAL, metadata)
            if tree(source) != tree(CANONICAL):
                raise RuntimeError('Local installation differs from the specified release DMG')
    print(json.dumps({'version': metadata['version'], 'sourceCommit': metadata['sourceCommit'], 'sha256': metadata['sha256'], 'installed': args.installed}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('inventory')
    for command in ['install', 'verify']:
        command_parser = sub.add_parser(command)
        command_parser.add_argument('--dmg', required=True, type=Path)
        command_parser.add_argument('--manifest', required=True, type=Path)
        if command == 'install':
            command_parser.add_argument('--helper', required=True)
            command_parser.add_argument('--receipt', required=True)
        else:
            command_parser.add_argument('--installed', action='store_true')
    args = parser.parse_args()
    if args.command == 'inventory':
        print(json.dumps(inventory([REPO]), ensure_ascii=False, indent=2))
    elif args.command == 'install':
        install(args)
    else:
        verify(args)


if __name__ == '__main__':
    main()
